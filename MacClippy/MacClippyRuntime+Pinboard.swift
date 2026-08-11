import Foundation

import MacClippyCore
import MacClippyPlatform

private struct MacClippyPinboardSearchContext {
    let parsed: MacClippySearchGrammar.Query
    let requestedKind: MacClippyContentKind?
    let needsKind: Bool
    let bareQuery: String
}

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

    func pinboardItems(
        pinboardID: RecordID,
        query: String,
        limit: Int = 64,
        offset: Int = 0
    ) throws -> [MacClippyHistoryEntry] {
        try withStoreLock {
            let board = try pinboardStore.fetch(id: pinboardID)
            return try pinboardItems(
                for: board,
                query: query,
                limit: limit,
                offset: offset
            )
        }
    }

    /// Loads a bounded search page against a stable board revision. The
    /// continuation is a member position, not a match count, so subsequent
    /// pages do not rescan the board from the beginning.
    func pinboardSearchPage(
        pinboardID: RecordID,
        query: String,
        limit: Int = 64,
        pageToken: MacClippyPinboardSearchPageToken? = nil,
        shouldCancel: () -> Bool = { false }
    ) throws -> MacClippyPinboardSearchPage {
        try withStoreLock {
            let board = try pinboardStore.fetch(id: pinboardID)
            if let pageToken, pageToken.boardModified != board.modified {
                throw MacClippyPinboardSearchPageError.boardChanged
            }
            return try pinboardSearchPage(
                for: board,
                query: query,
                limit: limit,
                memberOffset: pageToken?.memberOffset ?? 0,
                shouldCancel: shouldCancel
            )
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

    /// Resolves a bounded Pinboard page against the complete board membership.
    func pinboardItems(
        for board: Pinboard,
        query: String,
        limit: Int,
        offset: Int = 0
    ) throws -> [MacClippyHistoryEntry] {
        let pageLimit = min(max(limit, 0), 128)
        guard pageLimit > 0 else { return [] }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return try pinboardItems(for: board, limit: pageLimit, offset: offset)
        }

        guard let context = pinboardSearchContext(for: trimmedQuery) else { return [] }
        var skippedMatches = 0
        var selectedMetas: [ClipboardItemMeta] = []
        selectedMetas.reserveCapacity(pageLimit)

        let metadataBatchSize = 500
        boardScan: for start in stride(from: 0, to: board.itemIDs.count, by: metadataBatchSize) {
            let end = min(start + metadataBatchSize, board.itemIDs.count)
            let batchIDs = Array(board.itemIDs[start ..< end])
            let metas = try clipboardStore.metas(for: batchIDs)
            let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
            let knownKinds: [RecordID: MacClippyContentKind] = context.needsKind
                ? try clipboardStore.contentKinds(for: batchIDs)
                : [:]

            for id in batchIDs {
                guard let meta = metasByID[id] else { continue }
                guard try pinboardMetaMatches(meta, context: context, knownKinds: knownKinds) else { continue }
                if skippedMatches < max(0, offset) {
                    skippedMatches += 1
                    continue
                }
                selectedMetas.append(meta)
                if selectedMetas.count == pageLimit { break boardScan }
            }
        }

        let entriesByID = try entries(for: selectedMetas, validateContentKind: true)
        return selectedMetas.compactMap { entriesByID[$0.id] }
    }

    func pinboardSearchPage(
        for board: Pinboard,
        query: String,
        limit: Int,
        memberOffset: Int,
        shouldCancel: () -> Bool
    ) throws -> MacClippyPinboardSearchPage {
        let pageLimit = min(max(limit, 0), 128)
        guard pageLimit > 0 else {
            return MacClippyPinboardSearchPage(items: [], nextPageToken: nil)
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return try emptyPinboardSearchPage(
                for: board,
                limit: pageLimit,
                memberOffset: memberOffset,
                shouldCancel: shouldCancel
            )
        }

        guard let context = pinboardSearchContext(for: trimmedQuery) else {
            return MacClippyPinboardSearchPage(items: [], nextPageToken: nil)
        }
        return try filteredPinboardSearchPage(
            for: board,
            context: context,
            limit: pageLimit,
            memberOffset: memberOffset,
            shouldCancel: shouldCancel
        )
    }

    private func emptyPinboardSearchPage(
        for board: Pinboard,
        limit: Int,
        memberOffset: Int,
        shouldCancel: () -> Bool
    ) throws -> MacClippyPinboardSearchPage {
        var items: [MacClippyHistoryEntry] = []
        items.reserveCapacity(limit)
        var nextOffset = min(max(0, memberOffset), board.itemIDs.count)

        // Advance by members scanned, not by successfully decoded cards. A
        // deleted or corrupt record must not leave the cursor at the same
        // offset forever or produce an empty page that cannot load further.
        while nextOffset < board.itemIDs.count, items.count < limit {
            guard !shouldCancel() else {
                return MacClippyPinboardSearchPage(items: [], nextPageToken: nil)
            }
            let scanLimit = min(limit - items.count, board.itemIDs.count - nextOffset)
            let scannedItems = try pinboardItems(
                for: board,
                limit: scanLimit,
                offset: nextOffset
            )
            items.append(contentsOf: scannedItems)
            nextOffset += scanLimit
        }

        guard !shouldCancel() else {
            return MacClippyPinboardSearchPage(items: [], nextPageToken: nil)
        }
        let nextToken = nextOffset < board.itemIDs.count
            ? MacClippyPinboardSearchPageToken(boardModified: board.modified, memberOffset: nextOffset)
            : nil
        return MacClippyPinboardSearchPage(items: items, nextPageToken: nextToken)
    }

    private func filteredPinboardSearchPage(
        for board: Pinboard,
        context: MacClippyPinboardSearchContext,
        limit: Int,
        memberOffset: Int,
        shouldCancel: () -> Bool
    ) throws -> MacClippyPinboardSearchPage {
        var selectedMetas: [ClipboardItemMeta] = []
        selectedMetas.reserveCapacity(limit)

        let metadataBatchSize = 500
        var nextOffset = min(max(0, memberOffset), board.itemIDs.count)
        var start = nextOffset
        while start < board.itemIDs.count {
            guard !shouldCancel() else {
                return MacClippyPinboardSearchPage(items: [], nextPageToken: nil)
            }
            let end = min(start + metadataBatchSize, board.itemIDs.count)
            let batchIDs = Array(board.itemIDs[start ..< end])
            let metas = try clipboardStore.metas(for: batchIDs)
            let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
            let knownKinds: [RecordID: MacClippyContentKind] = context.needsKind
                ? try clipboardStore.contentKinds(for: batchIDs)
                : [:]

            for (index, id) in batchIDs.enumerated() {
                guard !shouldCancel() else {
                    return MacClippyPinboardSearchPage(items: [], nextPageToken: nil)
                }
                nextOffset = start + index + 1
                guard let meta = metasByID[id] else { continue }
                guard try pinboardMetaMatches(meta, context: context, knownKinds: knownKinds) else { continue }
                selectedMetas.append(meta)
                if selectedMetas.count == limit { break }
            }
            if selectedMetas.count == limit { break }
            start = end
        }

        let entriesByID = try entries(for: selectedMetas, validateContentKind: true)
        let items = selectedMetas.compactMap { entriesByID[$0.id] }
        let nextToken = nextOffset < board.itemIDs.count
            ? MacClippyPinboardSearchPageToken(boardModified: board.modified, memberOffset: nextOffset)
            : nil
        return MacClippyPinboardSearchPage(items: items, nextPageToken: nextToken)
    }

    private func pinboardSearchContext(for query: String) -> MacClippyPinboardSearchContext? {
        let parsed = MacClippySearchGrammar.parse(query)
        let requestedKinds = parsed.clauses.compactMap { clause -> MacClippyContentKind? in
            if case let .type(kind) = clause { return kind }
            return nil
        }
        guard Set(requestedKinds).count <= 1 else { return nil }
        return MacClippyPinboardSearchContext(
            parsed: parsed,
            requestedKind: requestedKinds.first,
            needsKind: !requestedKinds.isEmpty,
            bareQuery: parsed.bareTerms.joined(separator: " ")
        )
    }

    private func pinboardMetaMatches(
        _ meta: ClipboardItemMeta,
        context: MacClippyPinboardSearchContext,
        knownKinds: [RecordID: MacClippyContentKind]
    ) throws -> Bool {
        if context.parsed.hasStructuredClauses {
            guard let record = try searchRecord(
                for: meta,
                needsKind: context.needsKind,
                knownKinds: knownKinds
            ), MacClippySearchGrammar.matches(context.parsed, record: record) else {
                return false
            }
        }
        if !context.bareQuery.isEmpty,
           !meta.preview.localizedCaseInsensitiveContains(context.bareQuery) {
            return false
        }
        return context.requestedKind == nil || meta.contentKind == context.requestedKind
    }
}
