import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyPinboardPaginationTests: XCTestCase {
    private var tempRoot: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyPinboardPaginationTests-\(UUID().uuidString)",
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

    func testPinboardItemsPageFillsLiveItemsPastMissingMembers() throws {
        let board = try runtime.createPinboard(name: "Sparse first page", color: nil)
        let first = try runtime.appendTestRecord(.text("live first"))
        let second = try runtime.appendTestRecord(.text("live second"))
        try runtime.pin(recordID: first.id, to: board.id)
        try runtime.pin(recordID: second.id, to: board.id)
        _ = try runtime.pinboardStore.mutate(id: board.id) { board in
            for _ in 0 ..< 70 {
                board.itemIDs.insert(RecordID.generate(), at: 0)
            }
        }

        let loaded = try runtime.pinboards().first(where: { $0.id == board.id })
        XCTAssertEqual(loaded?.itemCount, 72)
        XCTAssertEqual(loaded?.items.map(\.id), [first.id, second.id])
        XCTAssertNil(loaded?.nextPageToken)
    }

    func testPinboardItemsPageContinuationUsesMemberOffset() throws {
        let board = try runtime.createPinboard(name: "Holes then live", color: nil)
        var liveIDs: [RecordID] = []
        for index in 0 ..< 70 {
            let record = try runtime.appendTestRecord(.text("live page \(index)"))
            liveIDs.append(record.id)
            try runtime.pin(recordID: record.id, to: board.id)
        }
        _ = try runtime.pinboardStore.mutate(id: board.id) { board in
            for _ in 0 ..< 10 {
                board.itemIDs.insert(RecordID.generate(), at: 0)
            }
        }

        let firstPage = try runtime.pinboardItemsPage(pinboardID: board.id, limit: 64)
        XCTAssertEqual(firstPage.items.map(\.id), Array(liveIDs.prefix(64)))
        let token = try XCTUnwrap(firstPage.nextPageToken)
        XCTAssertEqual(token.memberOffset, 74)

        let secondPage = try runtime.pinboardItemsPage(
            pinboardID: board.id,
            limit: 64,
            pageToken: token
        )
        XCTAssertEqual(secondPage.items.map(\.id), Array(liveIDs.suffix(6)))
        XCTAssertNil(secondPage.nextPageToken)
    }

    @MainActor
    func testDockPinboardLoadMoreUsesMemberOffsetPastMissingMembers() throws {
        let board = try runtime.createPinboard(name: "Dock sparse", color: nil)
        var liveIDs: [RecordID] = []
        for index in 0 ..< 70 {
            let record = try runtime.appendTestRecord(.text("dock sparse \(index)"))
            liveIDs.append(record.id)
            try runtime.pin(recordID: record.id, to: board.id)
        }
        _ = try runtime.pinboardStore.mutate(id: board.id) { board in
            for _ in 0 ..< 10 {
                board.itemIDs.insert(RecordID.generate(), at: 0)
            }
        }

        let model = MacClippyDockModel(runtime: runtime)
        model.beginSession()
        model.reload()
        wait {
            model.pinboards.first(where: { $0.id == board.id })?.items.count == 64
        }
        model.selectTab(.pinboard(board.id))
        let firstPage = try XCTUnwrap(model.pinboards.first(where: { $0.id == board.id }))
        XCTAssertEqual(firstPage.items.map(\.id), Array(liveIDs.prefix(64)))
        XCTAssertNotNil(firstPage.nextPageToken)

        model.loadMorePinboardIfNeeded(after: firstPage.items.last!.id)
        wait {
            model.pinboards.first(where: { $0.id == board.id })?.items.count == 70
        }
        let loaded = try XCTUnwrap(model.pinboards.first(where: { $0.id == board.id }))
        XCTAssertEqual(loaded.items.map(\.id), liveIDs)
        XCTAssertEqual(Set(loaded.items.map(\.id)).count, 70)
        XCTAssertNil(loaded.nextPageToken)
    }

    func testPinboardRecordIDsThrowAfterRepeatedBoardChanges() throws {
        let board = try runtime.createPinboard(name: "CmdA conflict", color: nil)
        let first = try runtime.appendTestRecord(.text("stable pin"))
        let second = try runtime.appendTestRecord(.text("first mutation"))
        let third = try runtime.appendTestRecord(.text("second mutation"))
        try runtime.pin(recordID: first.id, to: board.id)

        var cancelChecks = 0
        XCTAssertThrowsError(
            try runtime.pinboardRecordIDs(pinboardID: board.id, query: "") {
                cancelChecks += 1
                if cancelChecks == 1 {
                    try? runtime.pin(recordID: second.id, to: board.id)
                }
                if cancelChecks == 4 {
                    try? runtime.pin(recordID: third.id, to: board.id)
                }
                return false
            }
        ) { error in
            XCTAssertEqual(error as? MacClippyPinboardSearchPageError, .boardChanged)
        }
    }

    func testPinboardRecordIDsCancelAndConflictsRemainEmpty() throws {
        let board = try runtime.createPinboard(name: "CmdA empty", color: nil)
        let record = try runtime.appendTestRecord(.text("keep"))
        try runtime.pin(recordID: record.id, to: board.id)

        XCTAssertEqual(
            try runtime.pinboardRecordIDs(pinboardID: board.id, query: "") { true },
            []
        )
        XCTAssertEqual(
            try runtime.pinboardRecordIDs(pinboardID: board.id, query: "type:text type:image"),
            []
        )
        XCTAssertEqual(
            try runtime.pinboardRecordIDs(pinboardID: board.id, query: ""),
            [record.id]
        )
    }

    @MainActor
    func testRestartHistoryQueryLeavesPinboardSnapshotInPlace() throws {
        let board = try runtime.createPinboard(name: "Keep board", color: nil)
        let pinned = try runtime.appendTestRecord(.text("pinned stay"))
        try runtime.pin(recordID: pinned.id, to: board.id)
        for index in 0 ..< 8 {
            _ = try runtime.appendTestRecord(.text("history restart \(index)"))
        }

        let model = MacClippyDockModel(runtime: runtime)
        model.beginSession()
        model.reload()
        wait {
            model.pinboards.first(where: { $0.id == board.id })?.items.count == 1
                && model.historyItems.count == 8
        }
        model.selectTab(.pinboard(board.id))
        let pinboardIDs = model.pinboards.first(where: { $0.id == board.id })?.items.map(\.id)

        model.restartHistoryQuery()
        wait { model.isLoading == false }

        XCTAssertEqual(
            model.pinboards.first(where: { $0.id == board.id })?.items.map(\.id),
            pinboardIDs
        )
        if case let .pinboard(id) = model.selectedTab {
            XCTAssertEqual(id, board.id)
        } else {
            XCTFail("restartHistoryQuery must not change the selected pinboard tab")
        }
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
