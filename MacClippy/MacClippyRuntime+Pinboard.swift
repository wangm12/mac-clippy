import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    private static let pinboardPageSize = 64

    func pinboards(shouldCancel: () -> Bool = { false }) throws -> [MacClippyPinboardEntry] {
        let boards = try withStoreLock { try pinboardStore.list() }
        return try boards.compactMap { board in
            for _ in 0 ..< 2 {
                do {
                    let page = try pinboardItemsPage(
                        pinboardID: board.id,
                        limit: Self.pinboardPageSize,
                        shouldCancel: shouldCancel
                    )
                    let latestBoard = try withStoreLock { try pinboardStore.fetch(id: board.id) }
                    return MacClippyPinboardEntry(
                        board: latestBoard,
                        items: page.items,
                        itemCount: latestBoard.itemIDs.count,
                        nextPageToken: page.nextPageToken
                    )
                } catch MacClippyPinboardSearchPageError.boardChanged {
                    continue
                }
            }
            guard let latestBoard = try? withStoreLock({ try pinboardStore.fetch(id: board.id) }) else {
                return nil
            }
            return MacClippyPinboardEntry(
                board: latestBoard,
                items: [],
                itemCount: latestBoard.itemIDs.count,
                nextPageToken: nil
            )
        }
    }

    /// No-query pinboard pagination. Uses the same member-offset scanner as
    /// empty pinboard search so missing member IDs do not shrink the live
    /// page or skip later records.
    func pinboardItemsPage(
        pinboardID: RecordID,
        limit: Int = 64,
        pageToken: MacClippyPinboardSearchPageToken? = nil,
        shouldCancel: () -> Bool = { false }
    ) throws -> MacClippyPinboardSearchPage {
        try pinboardSearchPage(
            pinboardID: pinboardID,
            query: "",
            limit: limit,
            pageToken: pageToken,
            shouldCancel: shouldCancel
        )
    }

    func pinboardItems(
        pinboardID: RecordID,
        limit: Int = 64,
        offset: Int = 0
    ) throws -> [MacClippyHistoryEntry] {
        let board = try withStoreLock { try pinboardStore.fetch(id: pinboardID) }
        let pageToken = offset > 0
            ? MacClippyPinboardSearchPageToken(boardModified: board.modified, memberOffset: offset)
            : nil
        return try pinboardItemsPage(
            pinboardID: pinboardID,
            limit: limit,
            pageToken: pageToken
        ).items
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
}
