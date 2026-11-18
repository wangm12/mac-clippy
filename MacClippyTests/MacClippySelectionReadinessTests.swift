import AppKit
import MacClippyCore
import MacClippyPlatform
import XCTest

@testable import MacClippy

final class MacClippySelectionReadinessTests: XCTestCase {
    private var root: URL!
    private var board: NSPasteboard!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippySelectionReady-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        board = NSPasteboard(name: .init("MacClippySelectionReady-\(UUID())"))
        board.setString("unchanged", forType: .string)
        runtime = try MacClippyRuntime(
            paths: MacClippyPaths(rootURL: root),
            pasteInjector: MacClippyPasteInjector(pasteboard: board, isProcessTrusted: { false }),
            enableSnippetExpansion: false)
        MacClippyMainHop.setCaptureForTesting(true)
    }

    override func tearDownWithError() throws {
        runtime.closeForTesting()
        try FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testPendingSelectAllBlocksKeyboardAndModelActionsBeforeFreezingIDs() throws {
        for index in 0..<40 { _ = try runtime.appendTestRecord(.text("match \(index)")) }
        for visibleCount in [1, MacClippyDockModel.historyPageSize] {
            let controller = MacClippyDockController(runtime: runtime)
            let model = controller.model
            model.historyItems = try runtime.historyPage(limit: visibleCount, query: "").items
            let gate = DispatchSemaphore(value: 0)
            model.workQueue.async { gate.wait() }
            model.selectAllVisible()
            XCTAssertTrue(model.isSelectingAllMatches)
            XCTAssertFalse(model.selectionIsReady)
            let operation = model.operationGeneration
            var completions = 0
            _ = controller.applyKeyAction(.paste(plain: false))
            _ = controller.applyKeyAction(.copy)
            model.pasteSelectedAll { completions += 1 }
            model.copySelectedAll()
            model.pasteQueued { completions += 1 }
            XCTAssertEqual(model.operationGeneration, operation)
            gate.signal()
            model.workQueue.sync {}
            MacClippyMainHop.flushCapturedWork()
            XCTAssertEqual(completions, 0)
            XCTAssertNil(model.actionFeedback)
            XCTAssertEqual(board.string(forType: .string), "unchanged")
            XCTAssertEqual(model.selectionCount, 40)
            XCTAssertTrue(model.selectionIsReady)
            XCTAssertTrue(model.canMergeSelection)
            model.endSession()
        }
    }

    @MainActor
    func testReturnAfterSelectAllCompletesPastesEveryMatchedRecord() throws {
        for index in 0..<40 { _ = try runtime.appendTestRecord(.text("match \(index)")) }
        let model = MacClippyDockModel(runtime: runtime)
        model.historyItems = try runtime.historyPage(limit: MacClippyDockModel.historyPageSize, query: "").items
        model.selectAllVisible()
        MacClippyTestWait.until({ model.selectionIsReady }, failOnTimeout: true)
        var completed = false
        model.pasteSelectedAll { completed = true }
        MacClippyTestWait.until({ completed }, failOnTimeout: true)
        let text = try XCTUnwrap(board.string(forType: .string))
        XCTAssertEqual(text.split(separator: "\n").count, 40)
        for index in 0..<40 { XCTAssertTrue(text.split(separator: "\n").contains("match \(index)")) }
        model.endSession()
    }

    @MainActor
    func testUnsupportedOffscreenMatchPreventsSubsetPasteAfterSelectAll() throws {
        _ = try runtime.appendTestRecord(.files([root]))
        for index in 0..<40 { _ = try runtime.appendTestRecord(.text("match \(index)")) }
        let model = MacClippyDockModel(runtime: runtime)
        model.historyItems = try runtime.historyPage(limit: MacClippyDockModel.historyPageSize, query: "").items
        model.selectAllVisible()
        MacClippyTestWait.until({ model.selectionIsReady }, failOnTimeout: true)
        XCTAssertEqual(model.selectionCount, 41)
        XCTAssertFalse(model.canMergeSelection)
        var completed = false
        model.pasteSelectedAll { completed = true }
        MacClippyTestWait.until({ model.actionFeedback != nil }, failOnTimeout: true)
        guard case .multiPasteMixed = model.actionFeedback else { return XCTFail("Expected mixed selection feedback") }
        XCTAssertFalse(completed)
        XCTAssertEqual(board.string(forType: .string), "unchanged")
        model.endSession()
    }

    @MainActor
    func testEmptyPendingSelectionIsCancelledWhenQueryChanges() throws {
        let record = try runtime.appendTestRecord(.text("new query"))
        let model = MacClippyDockModel(runtime: runtime)
        let gate = DispatchSemaphore(value: 0)
        model.workQueue.async { gate.wait() }
        model.selectAllVisible()
        XCTAssertTrue(model.isSelectingAllMatches)
        XCTAssertTrue(model.selection.isEmpty)
        model.query = "new"
        XCTAssertTrue(model.selectionIsReady)
        gate.signal()
        model.workQueue.sync {}
        MacClippyMainHop.flushCapturedWork()
        XCTAssertFalse(model.isSelectingAllMatches)
        XCTAssertNil(model.selectAllWorkItem)
        model.historyItems = [try XCTUnwrap(runtime.entry(for: record))]
        model.historyQuery = "new"
        model.copyFocused()
        MacClippyTestWait.until({ self.board.string(forType: .string) == "new query" }, failOnTimeout: true)
        model.endSession()
    }

    @MainActor
    func testFailedFullSelectionCannotActOnFirstPageAndExplicitSelectionRecovers() throws {
        let damaged = try runtime.appendTestRecord(.text("old offscreen"))
        for index in 0..<40 { _ = try runtime.appendTestRecord(.text("match \(index)")) }
        let model = MacClippyDockModel(runtime: runtime)
        model.historyItems = try runtime.historyPage(limit: MacClippyDockModel.historyPageSize, query: "").items
        try runtime.databases[0].queue.write { connection in
            try connection.execute(sql: "UPDATE clipboard_records SET envelope = ? WHERE id = ?",
                                   arguments: [Data(repeating: 1, count: 32), damaged.id.rawValue])
        }
        model.selectAllVisible()
        MacClippyTestWait.until({ model.allSelectionFailed }, failOnTimeout: true)
        XCTAssertFalse(model.selectionIsReady)
        XCTAssertEqual(model.selectionCount, 0)
        XCTAssertNotNil(model.actionError)
        let operation = model.operationGeneration
        model.copySelectedAll()
        model.pasteSelectedAll { XCTFail("Failed scope must not paste") }
        model.pasteQueued { XCTFail("Failed scope must not queue") }
        model.requestPinSelection()
        model.requestDeleteSelected()
        model.deleteSelected()
        model.workQueue.sync {}
        MacClippyMainHop.flushCapturedWork()
        XCTAssertEqual(model.operationGeneration, operation)
        XCTAssertNil(model.modal)
        XCTAssertEqual(board.string(forType: .string), "unchanged")
        model.focusSelection(at: 0)
        XCTAssertTrue(model.selectionIsReady)
        model.copyFocused()
        MacClippyTestWait.until({ self.board.string(forType: .string) == "match 39" }, failOnTimeout: true)
        model.endSession()
    }

    @MainActor
    func testFixedRecordPinAndDeleteRemainAvailableAfterFullScopeFailure() throws {
        let pinned = try runtime.appendTestRecord(.text("pinned"))
        let other = try runtime.appendTestRecord(.text("other"))
        let pinboard = try runtime.createPinboard(name: "Target", color: nil)
        try runtime.pin(recordID: pinned.id, to: pinboard.id)
        let model = MacClippyDockModel(runtime: runtime)
        model.historyItems = try [pinned, other].map { try XCTUnwrap(runtime.entry(for: $0)) }
        model.pinboards = try runtime.pinboards()
        model.allSelectionFailed = true
        XCTAssertFalse(model.selectionIsReady)
        model.requestPinSelection(ids: [pinned.id])
        guard case .choosePinboard(let pinIDs, _) = model.modal else { return XCTFail("Missing fixed-ID chooser") }
        XCTAssertEqual(pinIDs, [pinned.id])
        model.dismissModal()
        model.requestDeleteRecords(ids: [pinned.id])
        guard case .confirmDeleteItems(let deleteIDs, let includesPinned, _) = model.modal else {
            return XCTFail("Missing fixed-ID delete confirmation")
        }
        XCTAssertEqual(deleteIDs, [pinned.id])
        XCTAssertTrue(includesPinned)
        model.dismissModal()
        XCTAssertEqual(try runtime.details(id: pinned.id).id, pinned.id)
        XCTAssertTrue(try runtime.pinboards()[0].board.itemIDs.contains(pinned.id))
        let operation = model.operationGeneration
        model.requestDeleteSelected()
        model.requestPinSelection()
        XCTAssertNil(model.modal)
        XCTAssertEqual(model.operationGeneration, operation)
        XCTAssertFalse(model.selectionIsReady)
        model.requestDeleteRecords(ids: [other.id])
        model.workQueue.sync {}
        MacClippyMainHop.flushCapturedWork()
        XCTAssertEqual(try runtime.details(id: pinned.id).id, pinned.id)
        XCTAssertThrowsError(try runtime.clipboardStore.body(for: other.id))
        XCTAssertEqual(board.string(forType: .string), "unchanged")
        model.endSession()
    }
}
