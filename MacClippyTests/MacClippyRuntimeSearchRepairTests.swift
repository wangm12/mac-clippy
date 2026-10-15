import AppKit
import Foundation
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyRuntimeSearchRepairTests: XCTestCase {
    @MainActor
    func testObserverCaptureAndSearchProceedBetweenRepairPages() throws {
        let fixture = try makeRuntime(label: "SearchRepairOverlap")
        let root = fixture.rootURL
        let environment = fixture.environment
        let runtime = fixture.runtime
        defer {
            MacClippyMaintenanceIOTestHooks.setAfterSearchRepairPageCommit(nil)
            runtime.closeForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        try seedIndexedRecords(40, in: runtime)
        runtime.start()
        runtime.drainMaintenanceQueueForShutdown()
        try runtime.markSearchIndexNeedsRepairForTest()
        let lifecycleToken = try XCTUnwrap(runtime.activeLifecycleToken())

        let gate = MacClippySearchRepairGate()
        let result = MacClippySearchRepairResultBox()
        let repairFinished = DispatchSemaphore(value: 0)
        MacClippyMaintenanceIOTestHooks.setAfterSearchRepairPageCommit {
            gate.blockFirstPass()
        }
        DispatchQueue.global(qos: .utility).async {
            result.store(Result { try runtime.repairSearchIndex(for: lifecycleToken) })
            repairFinished.signal()
        }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 10), .success)

        let visibleBetweenPages = try captureAndFindDuringRepair(
            runtime: runtime,
            pasteboard: environment.pasteboard
        )

        gate.resume.signal()
        XCTAssertEqual(repairFinished.wait(timeout: .now() + 30), .success)
        XCTAssertNoThrow(try result.result?.get())
        XCTAssertTrue(visibleBetweenPages, "search should observe the capture before repair finishes")
        XCTAssertTrue(try runtime.history(limit: 10, query: "concurrent repair capture token").contains {
            $0.preview == "concurrent repair capture token"
        })
        XCTAssertFalse(try runtime.searchStore.repairNeeded())
    }

    @MainActor
    func testEditAndDeleteCannotSlipBetweenRepairPageReadAndWrite() throws {
        let fixture = try makeRuntime(label: "SearchRepairFence")
        let root = fixture.rootURL
        let runtime = fixture.runtime
        defer {
            MacClippyMaintenanceIOTestHooks.setBeforeSearchRepairPageCommit(nil)
            runtime.closeForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        let edited = try runtime.appendTestRecord(.text("repair original edit token"))
        try runtime.edit(id: edited.id, text: "repair original edit token")
        let deleted = try runtime.appendTestRecord(.text("repair original delete token"))
        try runtime.edit(id: deleted.id, text: "repair original delete token")
        try seedIndexedRecords(32, in: runtime)
        runtime.start()
        runtime.drainMaintenanceQueueForShutdown()
        try runtime.markSearchIndexNeedsRepairForTest()
        let lifecycleToken = try XCTUnwrap(runtime.activeLifecycleToken())

        let gate = MacClippySearchRepairGate()
        let result = MacClippySearchRepairResultBox()
        let repairFinished = DispatchSemaphore(value: 0)
        MacClippyMaintenanceIOTestHooks.setBeforeSearchRepairPageCommit {
            gate.blockFirstPass()
        }
        DispatchQueue.global(qos: .utility).async {
            result.store(Result { try runtime.repairSearchIndex(for: lifecycleToken) })
            repairFinished.signal()
        }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 10), .success)

        let mutations = startMutationsWaitingForPageFence(
            runtime: runtime,
            editedID: edited.id,
            deletedID: deleted.id
        )
        XCTAssertEqual(mutations.editStarted.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(mutations.deleteStarted.wait(timeout: .now() + 3), .success)
        let editWaitedForPageFence = mutations.editFinished.wait(timeout: .now() + 0.15) == .timedOut
        let deleteWaitedForPageFence = mutations.deleteFinished.wait(timeout: .now() + 0.15) == .timedOut

        gate.resume.signal()
        XCTAssertEqual(mutations.editFinished.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(mutations.deleteFinished.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(repairFinished.wait(timeout: .now() + 30), .success)
        XCTAssertNoThrow(try result.result?.get())
        XCTAssertTrue(editWaitedForPageFence)
        XCTAssertTrue(deleteWaitedForPageFence)
        XCTAssertTrue(try runtime.history(limit: 10, query: "repair updated edit token").contains {
            $0.id == edited.id
        })
        XCTAssertTrue(try runtime.history(limit: 10, query: "repair original edit token").isEmpty)
        XCTAssertTrue(try runtime.history(limit: 10, query: "repair original delete token").isEmpty)
        XCTAssertTrue(try runtime.clipboardStore.metas(for: [deleted.id]).isEmpty)
    }

    @MainActor
    func testCancellationKeepsActiveSearchUsableAndRestoreDrainsRepair() throws {
        let fixture = try makeRuntime(label: "SearchRepairRestore")
        let root = fixture.rootURL
        let runtime = fixture.runtime
        defer {
            MacClippyMaintenanceIOTestHooks.setAfterSearchRepairPageCommit(nil)
            runtime.closeForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        try seedIndexedRecords(40, in: runtime)
        runtime.start()
        runtime.drainMaintenanceQueueForShutdown()
        try runtime.markSearchIndexNeedsRepairForTest()
        let gate = MacClippySearchRepairGate()
        let result = MacClippySearchRepairResultBox()
        let repairFinished = DispatchSemaphore(value: 0)
        MacClippyMaintenanceIOTestHooks.setAfterSearchRepairPageCommit {
            gate.blockFirstPass()
        }
        DispatchQueue.global(qos: .utility).async {
            result.store(Result { try runtime.repairSearchIndex() })
            repairFinished.signal()
        }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 10), .success)

        let barrierBox = MacClippySearchRepairBarrierBox()
        let barrierFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            barrierBox.store(runtime.beginRestoreMaintenanceIOBarrier())
            barrierFinished.signal()
        }
        let barrierWaitedForActiveRepair = barrierFinished.wait(timeout: .now() + 0.15) == .timedOut
        gate.resume.signal()

        XCTAssertEqual(repairFinished.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(barrierFinished.wait(timeout: .now() + 10), .success)
        XCTAssertThrowsError(try result.result?.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(barrierWaitedForActiveRepair)
        XCTAssertTrue(try runtime.searchStore.repairNeeded())
        XCTAssertTrue(try runtime.history(limit: 10, query: "indexed repair seed 0").contains {
            $0.preview == "indexed repair seed 0"
        })
        barrierBox.release()
    }

    @MainActor
    func testByteSplitRepairRefreshesPendingMetadataAndSkipsDeletedIDs() throws {
        let fixture = try makeRuntime(label: "SearchRepairPending")
        let root = fixture.rootURL
        let runtime = fixture.runtime
        let scenario = try seedPendingMetadataRepairScenario(runtime: runtime)
        defer {
            MacClippyMaintenanceIOTestHooks.setAfterSearchRepairPageCommit(nil)
            runtime.closeForTesting()
            try? FileManager.default.removeItem(at: root)
        }
        let lifecycleToken = try XCTUnwrap(runtime.activeLifecycleToken())
        let result = MacClippySearchRepairResultBox()
        let repairFinished = DispatchSemaphore(value: 0)
        MacClippyMaintenanceIOTestHooks.setAfterSearchRepairPageCommit {
            Self.mutatePendingMetadataOnce(scenario, runtime: runtime)
        }

        DispatchQueue.global(qos: .utility).async {
            result.store(Result { try runtime.repairSearchIndex(for: lifecycleToken) })
            repairFinished.signal()
        }

        XCTAssertEqual(repairFinished.wait(timeout: .now() + 60), .success)
        XCTAssertNoThrow(try result.result?.get())
        XCTAssertNil(scenario.mutationResult.errorDescription)
        XCTAssertTrue(scenario.mutationResult.didKeepPendingIDsOutOfFirstPage)
        XCTAssertGreaterThan(scenario.mutationResult.firstPageHeavyRecordCount, 0)
        XCTAssertLessThan(scenario.mutationResult.firstPageHeavyRecordCount, scenario.heavyIDs.count)
        XCTAssertGreaterThanOrEqual(scenario.mutationResult.committedPageCount, 2)
        XCTAssertEqual(
            try runtime.clipboardStore.metas(for: [scenario.labeled.id]).first?.customLabel,
            "repairlabelupdated"
        )
        XCTAssertTrue(
            try runtime.history(limit: 10, query: "repairlabelupdated").contains { $0.id == scenario.labeled.id }
        )
        XCTAssertTrue(try runtime.history(limit: 10, query: "pendinglabelbodyoriginal").contains {
            $0.id == scenario.labeled.id
        })
        XCTAssertTrue(try runtime.history(limit: 10, query: "pendingoldcustomlabel").isEmpty)
        XCTAssertTrue(try runtime.history(limit: 10, query: "pending-delete-original").isEmpty)
        XCTAssertTrue(try runtime.clipboardStore.metas(for: [scenario.deleted.id]).isEmpty)
        XCTAssertFalse(try runtime.searchStore.repairNeeded())
    }

}

extension MacClippyRuntimeSearchRepairTests {
    fileprivate func makeRuntime(
        label: String
    ) throws -> MacClippySearchRepairRuntimeFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippy\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let environment = MacClippyAppTestPasteboardEnvironment(label: label)
        let runtime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: root),
            observer: environment.observer,
            pasteInjector: environment.injector,
            enableSnippetExpansion: false,
            preferencesDefaults: environment.preferencesDefaults
        )
        return MacClippySearchRepairRuntimeFixture(
            rootURL: root,
            environment: environment,
            runtime: runtime
        )
    }

    fileprivate func startMutationsWaitingForPageFence(
        runtime: MacClippyRuntime,
        editedID: RecordID,
        deletedID: RecordID
    ) -> MacClippySearchRepairMutationOperations {
        let editStarted = DispatchSemaphore(value: 0)
        let editFinished = DispatchSemaphore(value: 0)
        let deleteStarted = DispatchSemaphore(value: 0)
        let deleteFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            editStarted.signal()
            _ = try? runtime.edit(id: editedID, text: "repair updated edit token")
            editFinished.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            deleteStarted.signal()
            try? runtime.delete(id: deletedID)
            deleteFinished.signal()
        }
        return MacClippySearchRepairMutationOperations(
            editStarted: editStarted,
            editFinished: editFinished,
            deleteStarted: deleteStarted,
            deleteFinished: deleteFinished
        )
    }

    fileprivate func seedIndexedRecords(
        _ count: Int,
        in runtime: MacClippyRuntime,
        startingAt date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws {
        for index in 0..<count {
            let body = "indexed repair seed \(index)"
            _ = try appendIndexed(body, in: runtime, now: date.addingTimeInterval(Double(index)))
        }
    }

    fileprivate func appendIndexed(
        _ text: String,
        in runtime: MacClippyRuntime,
        now: Date = Date()
    ) throws -> ClipboardItemMeta {
        let meta = try runtime.appendTestRecord(.text(text), sourceAppBundleID: nil, now: now)
        try runtime.withStoreLock {
            try runtime.searchStore.upsert(id: meta.id, text: text)
        }
        return meta
    }
    @MainActor
    private func captureAndFindDuringRepair(
        runtime: MacClippyRuntime,
        pasteboard: NSPasteboard
    ) throws -> Bool {
        runtime.observer.poll()
        let previousCount = pasteboard.changeCount
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("concurrent repair capture token", forType: .string))
        XCTAssertGreaterThan(pasteboard.changeCount, previousCount)
        runtime.observer.poll()
        runtime.drainCaptureQueueForTest()
        return try runtime.history(limit: 10, query: "concurrent repair capture token").contains {
            $0.preview == "concurrent repair capture token"
        }
    }

    @MainActor
    private func seedPendingMetadataRepairScenario(
        runtime: MacClippyRuntime
    ) throws -> SearchRepairPendingScenario {
        runtime.start()
        runtime.drainMaintenanceQueueForShutdown()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let labeled = try runtime.appendTestRecord(
            .text("pendinglabelbodyoriginal"),
            sourceAppBundleID: nil,
            now: base
        )
        try runtime.withStoreLock {
            _ = try runtime.clipboardStore.setCustomLabel(
                id: labeled.id,
                label: "pendingoldcustomlabel",
                now: base
            )
        }
        let deleted = try runtime.appendTestRecord(
            .text("pending-delete-original"),
            sourceAppBundleID: nil,
            now: base.addingTimeInterval(1)
        )

        for index in 0..<21 {
            _ = try appendIndexed(
                "small repair seed \(index)",
                in: runtime,
                now: base.addingTimeInterval(Double(index + 10))
            )
        }
        let largeBody = String(repeating: "repairbudgettoken ", count: 65_536)
        var heavyIDs: [RecordID] = []
        for index in 0..<9 {
            let meta = try runtime.appendTestRecord(
                .text(largeBody),
                sourceAppBundleID: nil,
                now: base.addingTimeInterval(Double(index + 31))
            )
            heavyIDs.append(meta.id)
        }
        let orderedMetas = try runtime.clipboardStore.list(limit: 32)
        XCTAssertEqual(orderedMetas.count, 32)
        XCTAssertEqual(Array(orderedMetas.suffix(2)).map(\.id), [deleted.id, labeled.id])
        try runtime.markSearchIndexNeedsRepairForTest()
        return SearchRepairPendingScenario(
            labeled: labeled,
            deleted: deleted,
            heavyIDs: heavyIDs,
            mutationResult: MacClippySearchRepairMutationResult()
        )
    }

    private static func mutatePendingMetadataOnce(
        _ scenario: SearchRepairPendingScenario,
        runtime: MacClippyRuntime
    ) {
        scenario.mutationResult.recordPageCommit()
        if scenario.mutationResult.claimPendingBoundaryCheck() {
            do {
                let pendingIDs = try runtime.searchStore.indexedRecordIDs(
                    matching: [scenario.labeled.id, scenario.deleted.id]
                )
                let indexedHeavyIDs = try runtime.searchStore.indexedRecordIDs(matching: scenario.heavyIDs)
                scenario.mutationResult.recordPendingBoundary(
                    passed: pendingIDs.isEmpty,
                    heavyIndexedCount: indexedHeavyIDs.count
                )
            } catch {
                scenario.mutationResult.record(error)
            }
        }
        guard scenario.mutationResult.claim() else { return }
        do {
            _ = try runtime.setCustomLabel(id: scenario.labeled.id, label: "repairlabelupdated")
            try runtime.delete(id: scenario.deleted.id)
        } catch {
            scenario.mutationResult.record(error)
        }
    }
}
