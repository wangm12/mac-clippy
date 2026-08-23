import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyHistoryPaginationTests: XCTestCase {
    private var tempRoot: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyHistoryPaginationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: tempRoot))
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testHistoryPagesContinueInOrderWithoutRepeatingRecords() throws {
        for index in 0..<20 {
            _ = try runtime.appendTestRecord(.text("history page " + String(index)))
        }

        let firstPage = try runtime.historyPage(limit: 16, query: "")
        XCTAssertEqual(firstPage.items.count, 16)
        guard let nextPageToken = firstPage.nextPageToken else {
            XCTFail("expected a continuation token for a second page")
            return
        }

        let secondPage = try runtime.historyPage(
            limit: 16,
            query: "",
            pageToken: nextPageToken
        )
        XCTAssertEqual(secondPage.items.count, 4)
        XCTAssertNil(secondPage.nextPageToken)

        let allIDs = firstPage.items.map(\.id) + secondPage.items.map(\.id)
        XCTAssertEqual(allIDs.count, 20)
        XCTAssertEqual(Set(allIDs).count, 20)
    }

    func testBareSearchPagesPreserveFTSOrderWithoutRepeatingRecords() throws {
        for index in 0..<20 {
            let record = try runtime.appendTestRecord(.text("search page " + String(index)))
            _ = try runtime.setCustomLabel(id: record.id, label: "search")
        }

        XCTAssertEqual(try runtime.searchStore.search(query: "search page", limit: 64).count, 20)
        let firstPage = try runtime.historyPage(limit: 16, query: "search page")
        XCTAssertEqual(firstPage.items.count, 16)
        guard let nextPageToken = firstPage.nextPageToken else {
            XCTFail("expected a continuation token for a bare search")
            return
        }
        let secondPage = try runtime.historyPage(
            limit: 16,
            query: "search page",
            pageToken: nextPageToken
        )

        let allIDs = firstPage.items.map(\.id) + secondPage.items.map(\.id)
        XCTAssertEqual(allIDs.count, 20)
        XCTAssertEqual(Set(allIDs).count, 20)
    }

    func testBareSearchPageInvalidatesWhenSearchIndexChanges() throws {
        for index in 0..<20 {
            let record = try runtime.appendTestRecord(.text("revision page " + String(index)))
            _ = try runtime.setCustomLabel(id: record.id, label: "revision")
        }

        let firstPage = try runtime.historyPage(limit: 16, query: "revision page")
        guard let nextPageToken = firstPage.nextPageToken else {
            XCTFail("expected a continuation token for a bare search")
            return
        }
        let changed = try XCTUnwrap(firstPage.items.first)
        _ = try runtime.setCustomLabel(id: changed.id, label: "changed index")

        XCTAssertThrowsError(
            try runtime.historyPage(
                limit: 16,
                query: "revision page",
                pageToken: nextPageToken
            )
        ) { error in
            XCTAssertEqual(error as? MacClippyHistoryPageError, .searchIndexChanged)
        }
    }

    func testPinboardSearchPagesUseMemberCursorWithoutRepeatingMatches() throws {
        let board = try runtime.createPinboard(name: "Searchable", color: nil)
        var records: [ClipboardItemMeta] = []
        for index in 0 ..< 40 {
            let record = try runtime.appendTestRecord(.text("pinboard cursor \(index)"))
            records.append(record)
            try runtime.pin(recordID: record.id, to: board.id)
        }

        let firstPage = try runtime.pinboardSearchPage(
            pinboardID: board.id,
            query: "pinboard cursor",
            limit: 16
        )
        XCTAssertEqual(firstPage.items.map(\.id), Array(records.prefix(16)).map(\.id))
        let token = try XCTUnwrap(firstPage.nextPageToken)
        XCTAssertEqual(token.memberOffset, 16)

        let secondPage = try runtime.pinboardSearchPage(
            pinboardID: board.id,
            query: "pinboard cursor",
            limit: 16,
            pageToken: token
        )
        XCTAssertEqual(secondPage.items.map(\.id), Array(records[16 ..< 32]).map(\.id))
        XCTAssertEqual(Set(firstPage.items.map(\.id)).intersection(Set(secondPage.items.map(\.id))).count, 0)
    }

    func testPinboardSearchPageInvalidatesWhenBoardMembershipChanges() throws {
        let board = try runtime.createPinboard(name: "Mutable", color: nil)
        for index in 0 ..< 20 {
            let record = try runtime.appendTestRecord(.text("mutable cursor \(index)"))
            try runtime.pin(recordID: record.id, to: board.id)
        }

        let firstPage = try runtime.pinboardSearchPage(
            pinboardID: board.id,
            query: "mutable cursor",
            limit: 16
        )
        let token = try XCTUnwrap(firstPage.nextPageToken)
        let newRecord = try runtime.appendTestRecord(.text("mutable cursor new"))
        try runtime.pin(recordID: newRecord.id, to: board.id)

        XCTAssertThrowsError(
            try runtime.pinboardSearchPage(
                pinboardID: board.id,
                query: "mutable cursor",
                limit: 16,
                pageToken: token
            )
        ) { error in
            XCTAssertEqual(error as? MacClippyPinboardSearchPageError, .boardChanged)
        }
    }

    func testPinboardEmptySearchCursorAdvancesPastMissingMembers() throws {
        let board = try runtime.createPinboard(name: "Sparse", color: nil)
        let first = try runtime.appendTestRecord(.text("sparse first"))
        let second = try runtime.appendTestRecord(.text("sparse second"))
        try runtime.pin(recordID: first.id, to: board.id)
        try runtime.pin(recordID: second.id, to: board.id)

        let missingID = RecordID.generate()
        _ = try runtime.pinboardStore.mutate(id: board.id) { board in
            board.itemIDs.insert(missingID, at: 0)
        }

        let firstPage = try runtime.pinboardSearchPage(
            pinboardID: board.id,
            query: "",
            limit: 1
        )
        XCTAssertEqual(firstPage.items.map(\.id), [first.id])
        XCTAssertEqual(firstPage.nextPageToken?.memberOffset, 2)

        let secondPage = try runtime.pinboardSearchPage(
            pinboardID: board.id,
            query: "",
            limit: 1,
            pageToken: try XCTUnwrap(firstPage.nextPageToken)
        )
        XCTAssertEqual(secondPage.items.map(\.id), [second.id])
        XCTAssertNil(secondPage.nextPageToken)
    }

    func testStructuredSearchPagesUseMetadataCursor() throws {
        for index in 0..<20 {
            _ = try runtime.appendTestRecord(.text("structured page " + String(index)))
        }

        let firstPage = try runtime.historyPage(limit: 16, query: "type:text")
        guard let nextPageToken = firstPage.nextPageToken else {
            XCTFail("expected a continuation token for a structured search")
            return
        }
        let secondPage = try runtime.historyPage(
            limit: 16,
            query: "type:text",
            pageToken: nextPageToken
        )

        let allIDs = firstPage.items.map(\.id) + secondPage.items.map(\.id)
        XCTAssertEqual(allIDs.count, 20)
        XCTAssertEqual(Set(allIDs).count, 20)
    }

    @MainActor
    func testDockPrefetchesHistoryBeforeTheLastCardAndPreservesLoadedOrder() throws {
        for index in 0..<20 {
            _ = try runtime.appendTestRecord(.text("dock history " + String(index)))
        }

        let model = MacClippyDockModel(runtime: runtime)
        model.reload()
        wait { model.historyItems.count == MacClippyDockModel.historyPageSize }
        XCTAssertTrue(model.historyHasMore)

        let firstPageIDs = model.historyItems.map(\.id)
        model.loadMoreHistoryIfNeeded(after: model.historyItems[12].id)
        // A second trigger while the first request is outstanding must not
        // submit a duplicate page request.
        model.loadMoreHistoryIfNeeded(after: model.historyItems[15].id)

        wait { model.historyItems.count == 20 }
        XCTAssertEqual(Array(model.historyItems.map(\.id).prefix(16)), firstPageIDs)
        XCTAssertEqual(Set(model.historyItems.map(\.id)).count, 20)
        XCTAssertFalse(model.historyHasMore)
    }

    @MainActor
    func testCommandASelectsAllHistoryIDsWithoutMaterializingEveryCard() throws {
        for index in 0..<40 {
            _ = try runtime.appendTestRecord(.text("select all history " + String(index)))
        }

        let model = MacClippyDockModel(runtime: runtime)
        model.reload()
        wait { model.historyItems.count == MacClippyDockModel.historyPageSize }
        XCTAssertEqual(model.historyItems.count, MacClippyDockModel.historyPageSize)

        model.selectAllVisible()

        wait { model.selectionCount == 40 }
        XCTAssertEqual(model.selectionCount, 40)
        XCTAssertTrue(model.hasMultipleSelection)
        XCTAssertEqual(model.orderedSelectedRecordIDs.count, 40)
        XCTAssertEqual(model.historyItems.count, MacClippyDockModel.historyPageSize)
    }

    @MainActor
    func testCommandARespectsCurrentHistorySearchQuery() throws {
        for index in 0..<12 {
            let record = try runtime.appendTestRecord(.text("matching select all " + String(index)))
            _ = try runtime.setCustomLabel(id: record.id, label: "matching")
        }
        for index in 0..<8 {
            let record = try runtime.appendTestRecord(.text("other history " + String(index)))
            _ = try runtime.setCustomLabel(id: record.id, label: "other")
        }

        let model = MacClippyDockModel(runtime: runtime)
        model.query = "matching"
        model.reload()
        wait { model.historyItems.count == 12 }

        model.selectAllVisible()

        wait { model.selectionCount == 12 }
        XCTAssertEqual(model.orderedSelectedRecordIDs.count, 12)
        XCTAssertTrue(model.orderedSelectedRecordIDs.allSatisfy { id in
            model.historyItems.contains { $0.id == id }
        })
    }

    func testHTMLHistoryPageUsesPersistedPreviewInsteadOfDecodingTheBody() throws {
        let html = "<p>" + String(repeating: "Hello ", count: 400) + "</p>"
        let meta = try runtime.appendTestRecord(.html(html))

        let page = try runtime.historyPage(limit: 16, query: "")
        let entry = try XCTUnwrap(page.items.first { $0.id == meta.id })

        XCTAssertEqual(entry.contentKind, .html)
        XCTAssertEqual(entry.preview, String(meta.preview.prefix(2_000)))
        XCTAssertLessThan(entry.preview.count, 200)
        XCTAssertFalse(entry.preview.contains("<p>"))
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
