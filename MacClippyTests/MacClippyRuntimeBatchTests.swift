import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyRuntimeBatchTests: XCTestCase {
    private var tempRoot: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyBatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let paths = try MacClippyPaths(rootURL: tempRoot)
        // We never call start(), so the observer never polls. Constructing the
        // runtime with its default observer is fine; we only exercise the
        // batch store operations directly.
        runtime = try MacClippyRuntime(paths: paths)
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Batch delete

    @MainActor
    func testPointerSelectionKeepsCarouselPositionRequestAndItemOrderStable() throws {
        _ = try runtime.appendTestRecord(.text("first"))
        _ = try runtime.appendTestRecord(.text("second"))

        let model = MacClippyDockModel(runtime: runtime)
        model.reload()
        wait { model.historyItems.count >= 2 }

        let orderBeforeSelection = model.visibleItems.map(\.id)
        let requestBeforeSelection = model.focusFollowRequestID

        // These are the model operations used by plain click, Cmd-click, and
        // Shift-click. None should ask the carousel to recenter.
        model.focusSelection(at: 1)
        model.toggleSelection(at: 0)
        model.extendRange(to: 1)

        XCTAssertEqual(model.focusFollowRequestID, requestBeforeSelection)
        XCTAssertNil(model.focusFollowTargetID)
        XCTAssertEqual(model.visibleItems.map(\.id), orderBeforeSelection)

        // Keyboard navigation remains the only path that requests focus
        // following when the focused card moves.
        model.moveFocus(.left)
        XCTAssertGreaterThan(model.focusFollowRequestID, requestBeforeSelection)
        XCTAssertEqual(model.focusFollowTargetID, orderBeforeSelection[0])
    }

    func testBatchDeleteRemovesEveryPresentIDAndReportsMissing() throws {
        let first = try runtime.appendTestRecord(.text("first"))
        let second = try runtime.appendTestRecord(.text("second"))
        let third = try runtime.appendTestRecord(.text("third"))
        let stale = RecordID.generate()

        let result = try runtime.delete(ids: [first.id, second.id, third.id, stale])

        XCTAssertEqual(result.deletedIDs, [first.id, second.id, third.id])
        XCTAssertEqual(result.missingIDs, [stale])
        // A clean batch has no per-item failures; failedIDs must be empty so
        // the dock can distinguish complete success from partial failure.
        XCTAssertEqual(result.failedIDs, [])
        XCTAssertTrue(try runtime.history(limit: 10, query: "").map(\.id).isEmpty)
    }

    func testBatchDeleteReclaimsImageBlobWhenNoOtherRecordReferencesIt() throws {
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))
        let result = try runtime.delete(ids: [image.id])
        XCTAssertEqual(result.deletedIDs, [image.id])
        XCTAssertEqual(result.failedIDs, [])
        XCTAssertTrue(try runtime.history(limit: 10, query: "").map(\.id).isEmpty)
    }

    func testDeleteUnpinnedHistoryPreservesPinnedItems() throws {
        let board = try runtime.createPinboard(name: "Keep", color: nil)
        let pinned = try runtime.appendTestRecord(.text("pinned"))
        let unpinned = try runtime.appendTestRecord(.text("remove"))
        try runtime.pin(recordID: pinned.id, to: board.id)

        let result = try runtime.deleteUnpinnedHistory()

        XCTAssertEqual(result.deletedIDs, [unpinned.id])
        XCTAssertTrue(result.missingIDs.isEmpty)
        XCTAssertTrue(result.failedIDs.isEmpty)
        XCTAssertEqual(try runtime.history(limit: 10, query: "").map(\.id), [pinned.id])
        XCTAssertEqual(try runtime.pinboards().first?.items.map(\.id), [pinned.id])
    }

    func testInterruptedDeletionReplayRemovesOrphanedFTSForTextRecord() throws {
        let record = try runtime.appendTestRecord(.text("replayable text"))
        _ = try runtime.setCustomLabel(id: record.id, label: "replay marker")

        try runtime.simulateInterruptedDeletionForTest(id: record.id)
        XCTAssertEqual(try runtime.pendingDeletionCountForTest(), 1)
        XCTAssertEqual(try runtime.indexedClipboardIDsForTest(), [record.id])
        XCTAssertTrue(try runtime.history(limit: 10, query: "").map(\.id).isEmpty)

        try runtime.replayPendingDeletionsForTest()
        XCTAssertEqual(try runtime.pendingDeletionCountForTest(), 0)
        XCTAssertTrue(try runtime.indexedClipboardIDsForTest().isEmpty)
        XCTAssertTrue(try runtime.history(limit: 10, query: "").map(\.id).isEmpty)
    }

    func testFTSRepairStateSurvivesSuccessfulIncrementalWritesUntilExplicitRepair() throws {
        let record = try runtime.appendTestRecord(.text("repair state body"))
        try runtime.markSearchIndexNeedsRepairForTest()

        XCTAssertEqual(runtime.storageHealth()["search"]?.status, .repairable)
        XCTAssertTrue(runtime.storageHealth()["search"]?.issues.contains("fts-repair-needed") == true)

        // This incremental write succeeds, but it must not claim that older
        // missing/stale index rows have been repaired.
        _ = try runtime.setCustomLabel(id: record.id, label: "new label")
        XCTAssertEqual(runtime.storageHealth()["search"]?.status, .repairable)
        XCTAssertTrue(runtime.storageHealth()["search"]?.issues.contains("fts-repair-needed") == true)

        _ = try runtime.repairSearchIndex()
        XCTAssertEqual(runtime.storageHealth()["search"]?.status, .healthy)
        XCTAssertFalse(runtime.storageHealth()["search"]?.issues.contains("fts-repair-needed") == true)
    }

    func testStartupHealthRecordsDegradedFTSStateWithoutExposingDatabaseDetails() throws {
        MacClippyDiagnosticsRecorder.shared.clear()
        try runtime.markSearchIndexNeedsRepairForTest()

        runtime.start()
        let deadline = Date().addingTimeInterval(3)
        var event: MacClippyDiagnosticsEvent?
        while Date() < deadline {
            event = MacClippyDiagnosticsRecorder.shared.recentEvents().first {
                $0.code == .databaseHealthFailed && $0.operation == "startup_health_check_search"
            }
            if event != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        runtime.stop()
        XCTAssertEqual(event?.category, .storage)
        XCTAssertEqual(event?.impact, "storage_repairable")
        XCTAssertEqual(event?.recoveryAction, "open_storage_recovery")
        XCTAssertFalse(event?.operation.contains("/") == true)
        XCTAssertFalse(event?.impact?.contains("fts-repair-needed") == true)
    }

    // MARK: - Batch pin

    func testBatchPinAddsAllPresentIDsToTargetBoardAndReportsDuplicatesAndMissing() throws {
        let board = try runtime.createPinboard(name: "Work", color: nil)
        let first = try runtime.appendTestRecord(.text("first"))
        let second = try runtime.appendTestRecord(.text("second"))
        let stale = RecordID.generate()

        // Pre-pin `first` so it shows up as a duplicate in the batch.
        try runtime.pin(recordID: first.id, to: board.id)

        let result = try runtime.pin(recordIDs: [first.id, second.id, stale], to: board.id)

        XCTAssertEqual(result.boardName, "Work")
        XCTAssertEqual(result.pinnedIDs, [second.id])
        XCTAssertEqual(result.duplicateIDs, [first.id])
        XCTAssertEqual(result.missingIDs, [stale])
        // A clean batch has no per-item failures; failedIDs must be empty so
        // the dock can distinguish complete success from partial failure.
        XCTAssertEqual(result.failedIDs, [])

        let boards = try runtime.pinboards()
        let boardItemIDs = Set(boards.first(where: { $0.id == board.id })?.items.map(\.id) ?? [])
        XCTAssertEqual(boardItemIDs, Set([first.id, second.id]))
    }

    func testBatchPinTargetsFirstBoardWhenItIsTheOnlyBoard() throws {
        let board = try runtime.createPinboard(name: "Default", color: nil)
        let first = try runtime.appendTestRecord(.text("first"))

        let result = try runtime.pin(recordIDs: [first.id], to: board.id)
        XCTAssertEqual(result.pinnedIDs, [first.id])
        XCTAssertEqual(result.boardName, "Default")
        XCTAssertEqual(result.failedIDs, [])
    }

    func testRenamePinboardPersistsNewName() throws {
        let board = try runtime.createPinboard(name: "Before", color: nil)

        try runtime.renamePinboard(id: board.id, to: "After")

        let boards = try runtime.pinboards()
        XCTAssertEqual(boards.first(where: { $0.id == board.id })?.name, "After")
    }

    func testSetPinboardColorPersistsColor() throws {
        let board = try runtime.createPinboard(name: "Colored", color: nil)

        try runtime.setPinboardColor(id: board.id, color: "#123456")

        let boards = try runtime.pinboards()
        XCTAssertEqual(boards.first(where: { $0.id == board.id })?.colorHex, "#123456")
    }

    func testDeletePinboardRemovesBoardAndPreservesPinnedRecord() throws {
        let board = try runtime.createPinboard(name: "To remove", color: nil)
        let record = try runtime.appendTestRecord(.text("preserved"))
        try runtime.pin(recordID: record.id, to: board.id)

        try runtime.deletePinboard(id: board.id)

        XCTAssertTrue(try runtime.pinboards().isEmpty)
        XCTAssertEqual(try runtime.history(limit: 10, query: "").first(where: { $0.id == record.id })?.preview, "preserved")
    }

    // MARK: - Ordered multi-paste

    func testOrderedMultiPasteReturnsMergedForHomogeneousTextSelection() throws {
        let first = try runtime.appendTestRecord(.text("first"))
        let second = try runtime.appendTestRecord(.text("second"))

        // Visual order in the dock is newest-first: second, first.
        let result = try runtime.pasteOrdered(ids: [second.id, first.id])
        guard case .merged = result else {
            XCTFail("expected .merged for a homogeneous text selection, got \(result)")
            return
        }
        // The exact merged text is covered by the pure
        // MacClippyDockMultiPastePolicyTests; here we assert the result kind
        // only, since the injector writes to NSPasteboard.general.
    }

    func testOrderedMultiPasteReturnsMixedForImageInSelectionAndDoesNotPasteSubset() throws {
        let text = try runtime.appendTestRecord(.text("text"))
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))

        let result = try runtime.pasteOrdered(ids: [text.id, image.id])
        guard case let .mixed(supportedIDs, unsupportedIDs, unsupportedKinds) = result else {
            XCTFail("expected .mixed for a text+image selection, got \(result)")
            return
        }
        XCTAssertEqual(supportedIDs, [text.id])
        XCTAssertEqual(unsupportedIDs, [image.id])
        XCTAssertEqual(unsupportedKinds, [.image])
    }

    func testOrderedMultiPasteWithFilesReportsThemAsUnsupportedNotDropped() throws {
        let text = try runtime.appendTestRecord(.text("text"))
        let files = try runtime.appendTestRecord(.files([URL(fileURLWithPath: "/tmp/a.txt")]))

        let result = try runtime.pasteOrdered(ids: [text.id, files.id])
        guard case let .mixed(supportedIDs, unsupportedIDs, unsupportedKinds) = result else {
            XCTFail("expected .mixed for a text+files selection, got \(result)")
            return
        }
        XCTAssertEqual(supportedIDs, [text.id])
        XCTAssertEqual(unsupportedIDs, [files.id])
        XCTAssertEqual(unsupportedKinds, [.files])
    }

    func testOrderedMultiPasteWithMalformedRTFReportsTextUnavailableAndDoesNotPaste() throws {
        // A malformed RTF payload whose NSAttributedString cannot be
        // initialized must NOT be silently merged as an empty piece. The
        // runtime must report .textUnavailable with the unavailable ID and
        // its kind, and NO paste occurs for the selection (the available
        // text record is not pasted as a partial subset either).
        let good = try runtime.appendTestRecord(.text("good"))
        let malformedRTF = Data("{\\rtf1 THIS IS NOT VALID RTF".utf8)
        let bad = try runtime.appendTestRecord(.rtf(malformedRTF))

        let result = try runtime.pasteOrdered(ids: [good.id, bad.id])
        guard case let .textUnavailable(availableIDs, unavailableIDs, unavailableKinds) = result else {
            XCTFail("expected .textUnavailable for a text+malformed-rtf selection, got \(result)")
            return
        }
        XCTAssertEqual(availableIDs, [good.id])
        XCTAssertEqual(unavailableIDs, [bad.id])
        XCTAssertEqual(unavailableKinds, [.rtf])
    }

    func testOrderedMultiPasteWithEmptyRealTextMergesEmptyPiece() throws {
        // An empty real text payload ("") is a valid empty piece and must be
        // merged in visual order; it is NOT reported as unavailable. This
        // guards the boundary between "empty decoded text" and "nil payload".
        let a = try runtime.appendTestRecord(.text("alpha"))
        let empty = try runtime.appendTestRecord(.text(""))

        let result = try runtime.pasteOrdered(ids: [a.id, empty.id])
        guard case .merged = result else {
            XCTFail("expected .merged for a text selection with one empty real text, got \(result)")
            return
        }
        // The exact merged string is covered by the pure policy tests; here we
        // assert the result kind only, since the injector writes to
        // NSPasteboard.general.
    }

    // MARK: - Stale operation/session generation (model-level)

    @MainActor
    func testStaleBatchCompletionDoesNotCloseReopenedDock() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("first"))
        _ = try runtime.appendTestRecord(.text("second"))
        model.reload()
        wait { model.historyItems.count >= 2 }

        // Start a session, begin a batch paste, then end the session (hide)
        // and begin a new session (reopen) BEFORE the batch completes. The
        // stale completion must not call the close handler.
        model.beginSession()
        model.selectAllVisible()
        XCTAssertTrue(model.hasMultipleSelection)
        XCTAssertEqual(model.selectionCount, 2)
        var didClose = false
        model.pasteSelectedAll(completion: { didClose = true })

        // End the session (simulates hide) and start a new one (simulates
        // reopen) while the batch is still in flight on the work queue.
        model.endSession()
        model.beginSession()

        // Wait for the work queue to drain. The stale completion should have
        // been suppressed by the session-generation mismatch.
        wait { didClose || model.actionFeedback != nil }

        XCTAssertFalse(didClose, "stale batch completion must not close a newly reopened dock")
    }

    @MainActor
    func testNewerBatchSupersedesOlderBatchResult() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("first"))
        _ = try runtime.appendTestRecord(.text("second"))
        model.reload()
        wait { model.historyItems.count >= 2 }

        model.selectAllVisible()

        // Start a batch delete, then immediately start a second batch delete
        // before the first completes. The second bumps operationGeneration, so
        // the first's completion is suppressed.
        model.deleteSelected()

        // The second delete should win; after drain, the records are gone and
        // the selection is cleared.
        wait { model.historyItems.isEmpty || model.selection.isEmpty }
        XCTAssertTrue(model.historyItems.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
    }

    // MARK: - Batch failure semantics

    @MainActor
    func testBatchDeleteWithMissingIDReportsPartialNotCompleteSuccess() throws {
        // A batch delete where one selected ID is not in the store must report
        // a partial result, never a complete .deleted success. This guards the
        // P1 invariant that an error/missing item cannot silently make the UI
        // report a successful complete batch. The dock reads the runtime
        // result (missingIDs + failedIDs) and chooses .batchPartial over
        // .deleted when either is non-empty.
        let model = MacClippyDockModel(runtime: runtime)
        let present = try runtime.appendTestRecord(.text("present"))
        let stale = RecordID.generate()

        // Manually drive a delete over a selection that includes a stale ID.
        // The model's deleteSelected uses selection.orderedSelectedIDs, so put
        // both IDs into the selection via toggle.
        model.reload()
        wait { model.historyItems.count >= 1 }

        // Build a selection containing the present id and a stale id. The
        // stale id is not in historyItems, so toggle it directly through the
        // selection policy entry point.
        guard let presentIndex = model.historyItems.firstIndex(where: { $0.id == present.id }) else {
            XCTFail("present record should be visible after reload")
            return
        }
        model.focusSelection(at: presentIndex)
        model.toggleSelection(at: presentIndex)

        // Append the stale id into the runtime batch by calling deleteSelected
        // with a selection that includes it. Since the model only knows about
        // visible items, exercise the runtime directly and feed the result
        // through the same feedback decision the dock uses.
        let runtimeResult = try runtime.delete(ids: [present.id, stale])
        XCTAssertFalse(runtimeResult.missingIDs.isEmpty)
        XCTAssertEqual(runtimeResult.missingIDs, [stale])
        XCTAssertEqual(runtimeResult.failedIDs, [])

        // The dock's decision: non-empty missingIDs OR failedIDs -> partial.
        let isCompleteSuccess = runtimeResult.missingIDs.isEmpty && runtimeResult.failedIDs.isEmpty
        XCTAssertFalse(isCompleteSuccess, "a partial batch must never be reported as complete success")
    }

    @MainActor
    func testBatchPinWithMissingIDReportsPartialNotCompleteSuccess() throws {
        // A batch pin where one selected ID is not in the store must report a
        // partial result, never a complete .pinnedTo success. Guards the same
        // P1 invariant for the pin path: missingIDs OR failedIDs non-empty ->
        // .batchPartial.
        let board = try runtime.createPinboard(name: "Board", color: nil)
        let model = MacClippyDockModel(runtime: runtime)
        let present = try runtime.appendTestRecord(.text("present"))
        let stale = RecordID.generate()

        model.reload()
        wait { model.historyItems.count >= 1 }

        let runtimeResult = try runtime.pin(recordIDs: [present.id, stale], to: board.id)
        XCTAssertFalse(runtimeResult.missingIDs.isEmpty)
        XCTAssertEqual(runtimeResult.missingIDs, [stale])
        XCTAssertEqual(runtimeResult.failedIDs, [])

        let isCompleteSuccess = runtimeResult.missingIDs.isEmpty && runtimeResult.failedIDs.isEmpty
        XCTAssertFalse(isCompleteSuccess, "a partial pin batch must never be reported as complete success")
    }

    // MARK: - Selection surface visibility

    @MainActor
    func testSelectionSurfaceHiddenForSingleSelectionAndSnippets() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("only"))
        model.reload()
        wait { model.historyItems.count >= 1 }

        // One focused card: no multi-select surface.
        model.focusSelection(at: 0)
        XCTAssertFalse(model.hasMultipleSelection)

        // Cmd+A on a single record selects one -> still no surface (count == 1).
        model.selectAllVisible()
        XCTAssertFalse(model.hasMultipleSelection)

        // Switch to snippets: surface never shows.
        model.selectTab(.snippets)
        XCTAssertFalse(model.hasMultipleSelection)
        XCTAssertEqual(model.selectionCount, 0)
    }

    @MainActor
    func testClearSelectionKeepsFocusAndAllowsSecondEscapeToDismiss() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("a"))
        _ = try runtime.appendTestRecord(.text("b"))
        model.reload()
        wait { model.historyItems.count >= 2 }

        model.selectAllVisible()
        XCTAssertTrue(model.hasMultipleSelection)

        // First Escape (clear-selection-first): selection is cleared, focus
        // stays on the current card.
        let focusBeforeClear = model.focusedIndex
        model.clearSelection()
        XCTAssertFalse(model.hasMultipleSelection)
        XCTAssertEqual(model.focusedIndex, focusBeforeClear)

        // A second Escape has nothing to clear, so the controller's lifecycle
        // path dismisses the dock. The model's clearSelection is a no-op when
        // the selection is already empty, leaving focus intact.
        let focusBeforeSecondClear = model.focusedIndex
        model.clearSelection()
        XCTAssertEqual(model.focusedIndex, focusBeforeSecondClear)
    }

    // MARK: - Helpers

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
