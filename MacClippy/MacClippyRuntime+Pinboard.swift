import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    private static let pinboardPageSize = 64

    func pinboards() throws -> [MacClippyPinboardEntry] {
        try withStoreLock {
            try pinboardStore.list().map { board in
                MacClippyPinboardEntry(
                    board: board,
                    items: try pinboardItems(for: board, limit: Self.pinboardPageSize, offset: 0),
                    itemCount: board.itemIDs.count
                )
            }
        }
    }

    func pinboardItems(
        pinboardID: RecordID,
        limit: Int = 64,
        offset: Int = 0
    ) throws -> [MacClippyHistoryEntry] {
        try withStoreLock {
            let board = try pinboardStore.fetch(id: pinboardID)
            return try pinboardItems(for: board, limit: limit, offset: offset)
        }
    }

    func createPinboard(name: String, color: String?) throws -> Pinboard {
        try withStoreLock {
            try pinboardStore.create(name: name, color: color)
        }
    }

    func renamePinboard(id: RecordID, to name: String) throws {
        try withStoreLock {
            try pinboardStore.rename(id: id, to: name)
        }
    }

    func setPinboardColor(id: RecordID, color: String) throws {
        try withStoreLock {
            _ = try pinboardStore.mutate(id: id) { $0.color = color }
        }
    }

    func deletePinboard(id: RecordID) throws {
        try withStoreLock {
            try pinboardStore.delete(id: id)
        }
    }

    func pin(recordID: RecordID, to pinboardID: RecordID) throws {
        try withStoreLock {
            let board = try pinboardStore.fetch(id: pinboardID)
            guard try !clipboardStore.metas(for: [recordID]).isEmpty else {
                throw MacClippyStoreError.recordNotFound
            }
            guard !board.itemIDs.contains(recordID) else { return }
            try pinboardStore.addItem(recordID, to: pinboardID)
        }
    }

    func pinboardItems(
        for board: Pinboard,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [MacClippyHistoryEntry] {
        let normalizedOffset = max(0, offset)
        let itemLimit = max(0, limit ?? board.itemIDs.count)
        let orderedIDs = Array(board.itemIDs.dropFirst(normalizedOffset).prefix(itemLimit))
        guard !orderedIDs.isEmpty else { return [] }

        let metas = try clipboardStore.metas(for: orderedIDs)
        let metaByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
        var entriesByID: [RecordID: MacClippyHistoryEntry] = [:]
        var uncachedMetas: [ClipboardItemMeta] = []

        for itemID in orderedIDs {
            guard let meta = metaByID[itemID] else { continue }
            let key = cacheKey(for: meta)
            if let cached = historyEntryCache.object(forKey: key) {
                entriesByID[itemID] = cached.entry
            } else {
                uncachedMetas.append(meta)
            }
        }

        if !uncachedMetas.isEmpty {
            entriesByID.merge(try entries(for: uncachedMetas, validateContentKind: true)) { _, newer in newer }
        }
        return orderedIDs.compactMap { entriesByID[$0] }
    }
}
