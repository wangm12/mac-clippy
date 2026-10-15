import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyRuntimeBatchTests: XCTestCase {
    private var tempRoot: URL!
    private var pasteboardEnvironment: MacClippyAppTestPasteboardEnvironment!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyBatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let paths = try MacClippyPaths(rootURL: tempRoot)
        pasteboardEnvironment = MacClippyAppTestPasteboardEnvironment(label: "MacClippyBatchTests")
        runtime = try MacClippyRuntime(
            paths: paths,
            observer: pasteboardEnvironment.observer,
            pasteInjector: pasteboardEnvironment.injector,
            enableSnippetExpansion: false,
            preferencesDefaults: pasteboardEnvironment.preferencesDefaults
        )
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        pasteboardEnvironment = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testCreateBackupWritesAValidSnapshotOfLiveStorage() throws {
        _ = try runtime.appendTestRecord(.text("keep-me"))
        let snapshot = tempRoot.appendingPathComponent("snapshot", isDirectory: true)

        let manifest = try runtime.createBackup(at: snapshot)

        XCTAssertEqual(
            Set(manifest.databaseNames),
            Set(MacClippyBackupSettingsPolicy.requiredDatabaseNames)
        )
        let sidecars = manifest.databaseNames.flatMap { name in
            ["-wal", "-shm", "-journal"].map { snapshot.appendingPathComponent(name + ".sqlite" + $0).path }
        }.filter { FileManager.default.fileExists(atPath: $0) }
        XCTAssertTrue(sidecars.isEmpty, "Backup contains SQLite sidecars: \(sidecars)")
        let keySource = runtime.clipboardStore.backupKeySource
        let validation = try MacClippyBackup.validate(at: snapshot, keySource: keySource)
        XCTAssertTrue(MacClippyBackupSettingsPolicy.canRestore(validation))
        XCTAssertEqual(validation.databaseRowCounts["clipboard"], 1)
        XCTAssertTrue(MacClippyBackupSettingsPolicy.containsManifest(at: snapshot))

        let restoredRoot = tempRoot.appendingPathComponent("restored", isDirectory: true)
        let restoredValidation = try MacClippyBackup.installIntoLiveRoot(
            from: snapshot,
            liveRootURL: restoredRoot,
            keySource: keySource
        )
        XCTAssertTrue(MacClippyBackupSettingsPolicy.canRestore(restoredValidation))
        let restoredPaths = try MacClippyPaths(rootURL: restoredRoot)
        let restoredDatabase = try MacClippyDatabase(url: restoredPaths.clipboardDatabaseURL, readOnly: true)
        defer { try? restoredDatabase.queue.close() }
        XCTAssertEqual(
            restoredDatabase.healthCheck(requiredTables: ["clipboard_records"], mode: .bounded).status,
            .healthy
        )
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

    func testBatchDeleteDoesNotMisclassifyDuplicatePresentIDsAsMissing() throws {
        let record = try runtime.appendTestRecord(.text("duplicate delete"))

        let result = try runtime.delete(ids: [record.id, record.id])

        XCTAssertEqual(result.deletedIDs, [record.id])
        XCTAssertTrue(result.missingIDs.isEmpty)
        XCTAssertTrue(result.failedIDs.isEmpty)
    }

    func testEditRollsBackClipboardAndSearchProjectionWhenSearchWriteFails() throws {
        let record = try runtime.appendTestRecord(.text("original edit text"))
        try runtime.databases[1].queue.close()

        XCTAssertThrowsError(try runtime.edit(id: record.id, text: "edited text"))
        XCTAssertEqual(
            try runtime.clipboardStore.body(for: record.id),
            .text("original edit text")
        )
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
            Thread.sleep(forTimeInterval: 0.01)
            MacClippyMainHop.flushCapturedWork()
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

    func testBatchPinDoesNotReportTheSamePresentIDTwice() throws {
        let board = try runtime.createPinboard(name: "Work", color: nil)
        let record = try runtime.appendTestRecord(.text("duplicate pin"))

        let result = try runtime.pin(recordIDs: [record.id, record.id], to: board.id)

        XCTAssertEqual(result.pinnedIDs, [record.id])
        XCTAssertTrue(result.duplicateIDs.isEmpty)
        XCTAssertTrue(result.missingIDs.isEmpty)
        XCTAssertTrue(result.failedIDs.isEmpty)
    }

    func testBatchPinTargetsFirstBoardWhenItIsTheOnlyBoard() throws {
        let board = try runtime.createPinboard(name: "Default", color: nil)
        let first = try runtime.appendTestRecord(.text("first"))

        let result = try runtime.pin(recordIDs: [first.id], to: board.id)
        XCTAssertEqual(result.pinnedIDs, [first.id])
        XCTAssertEqual(result.boardName, "Default")
        XCTAssertEqual(result.failedIDs, [])
    }

    func testPinboardProjectionLoadsBodiesInBoundedPages() throws {
        let board = try runtime.createPinboard(name: "Large", color: nil)
        var recordIDs: [RecordID] = []
        for _ in 0 ..< 70 {
            let record = try runtime.appendTestRecord(.text("pinboard-(index)"))
            recordIDs.append(record.id)
            try runtime.pin(recordID: record.id, to: board.id)
        }

        let firstPage = try runtime.pinboards().first(where: { $0.id == board.id })
        XCTAssertEqual(firstPage?.itemCount, 70)
        XCTAssertEqual(firstPage?.items.count, 64)

        let secondPage = try runtime.pinboardItems(pinboardID: board.id, offset: 64)
        XCTAssertEqual(secondPage.count, 6)
        XCTAssertEqual(firstPage?.items.map(\.id) ?? [], Array(recordIDs.prefix(64)))
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

    // MARK: - Helpers

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        MacClippyTestWait.until(condition, timeout: timeout)
    }
}

extension MacClippyRuntimeBatchTests {
    func testRestoreShutdownExplicitlyClosesAllStorageQueues() throws {
        let closed = expectation(description: "restore shutdown runs off the main thread")
        let runtimeToClose = runtime!
        DispatchQueue.global(qos: .utility).async {
            do {
                try runtimeToClose.closeStorageForRestore()
            } catch {
                XCTFail("restore shutdown failed: \(error)")
            }
            closed.fulfill()
        }
        wait(for: [closed], timeout: 5)

        for database in runtime.databases {
            XCTAssertEqual(database.healthCheck().status, .unrecoverable)
        }
        XCTAssertThrowsError(
            try runtime.thumbnailDiskCache.store(
                Data([1, 2, 3]),
                id: RecordID.generate(),
                maxPixelSize: 32
            )
        )
    }
}
