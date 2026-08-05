import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

// Focused tests for the mixed-content sequential queue paste feature. Queue
// paste processes the ordered selected IDs one at a time in visual order,
// injecting a separate Cmd+V per record so mixed selections (text + image +
// files) can each be consumed by the target app. This is NOT the homogeneous-
// only pasteOrdered path. These tests use a recording injector whose
// postEvents closure counts every paste keystroke (and can be switched to
// .manualPasteRequired), mirroring MacClippyCopyAllTests/MacClippyTransformTests.
final class MacClippyQueuePasteTests: XCTestCase {
    private var tempRoot: URL!
    private var pasteboard: NSPasteboard!
    private var postedEventCount: Int = 0
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyQueuePasteTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyQueuePaste-\(UUID().uuidString)"))
        postedEventCount = 0

        let paths = try MacClippyPaths(rootURL: tempRoot)
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { [weak self] _, _ in
                self?.postedEventCount &+= 1
            }
        )
        runtime = try MacClippyRuntime(paths: paths, pasteInjector: injector)
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        pasteboard = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Runtime: mixed-content order and frequency bumps

    func testPasteQueuedMixedTextImageFilesInjectsEachInOrderAndBumpsFrequency() throws {
        let text = try runtime.appendTestRecord(.text("alpha"))
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))
        let files = try runtime.appendTestRecord(.files([URL(fileURLWithPath: "/tmp/one.txt")]))

        // Visual order: text, image, files. Each record gets its own paste.
        let result = try runtime.pasteQueued(ids: [text.id, image.id, files.id])

        guard case let .completed(injectedIDs, unavailableIDs, unavailableKinds) = result else {
            XCTFail("expected .completed for a fully-pasteable mixed selection, got \(result)")
            return
        }
        XCTAssertEqual(injectedIDs, [text.id, image.id, files.id], "every record should be injected in visual order")
        XCTAssertTrue(unavailableIDs.isEmpty, "no record should be unavailable")
        XCTAssertTrue(unavailableKinds.isEmpty)

        // One Cmd+V per record => three posted events.
        XCTAssertEqual(postedEventCount, 3, "pasteQueued must post one paste keystroke per record")

        // The last injected record's content is what the pasteboard holds now
        // (files). The earlier writes are overwritten in turn; this confirms
        // each record was prepared and injected.
        let pastedURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertEqual(pastedURLs, [URL(fileURLWithPath: "/tmp/one.txt")])

        // Frequency bumps only for injected records, exactly once each.
        let metas = try runtime.history(limit: 10, query: "")
        let byID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0.meta.frequency) })
        XCTAssertEqual(byID[text.id], 1, "injected text frequency must bump once")
        XCTAssertEqual(byID[image.id], 1, "injected image frequency must bump once")
        XCTAssertEqual(byID[files.id], 1, "injected files frequency must bump once")
    }

    func testPasteQueuedFollowsSuppliedVisualOrderNotInsertionOrder() throws {
        let first = try runtime.appendTestRecord(.text("first"))
        let second = try runtime.appendTestRecord(.text("second"))
        let third = try runtime.appendTestRecord(.text("third"))

        // Supply a non-insertion visual order and assert injection follows it.
        let result = try runtime.pasteQueued(ids: [third.id, first.id, second.id])

        guard case let .completed(injectedIDs, _, _) = result else {
            XCTFail("expected .completed, got \(result)")
            return
        }
        XCTAssertEqual(injectedIDs, [third.id, first.id, second.id], "injection order must follow the supplied visual order")
        XCTAssertEqual(postedEventCount, 3)

        // The last injected record is second; the pasteboard holds its text.
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
    }

    // MARK: - Runtime: malformed RTF / missing record explicit unavailable

    func testPasteQueuedMalformedRTFIsExplicitlyUnavailableAndContinuesWithLaterRecords() throws {
        let good = try runtime.appendTestRecord(.text("good"))
        let malformedRTF = Data("{\\rtf1 THIS IS NOT VALID RTF".utf8)
        let bad = try runtime.appendTestRecord(.rtf(malformedRTF))
        let later = try runtime.appendTestRecord(.text("later"))

        // good, bad(malformed), later: the malformed RTF must be reported
        // unavailable and the queue must CONTINUE with `later`.
        let result = try runtime.pasteQueued(ids: [good.id, bad.id, later.id])

        guard case let .completed(injectedIDs, unavailableIDs, unavailableKinds) = result else {
            XCTFail("expected .completed, got \(result)")
            return
        }
        XCTAssertEqual(injectedIDs, [good.id, later.id], "good and later must be injected; bad must not")
        XCTAssertEqual(unavailableIDs, [bad.id], "the malformed RTF record must be explicitly unavailable")
        XCTAssertEqual(unavailableKinds, [.rtf], "the unavailable kind must be rtf")

        // Two injections (good + later), NOT three: bad is not injected.
        XCTAssertEqual(postedEventCount, 2, "the malformed record must not post a paste keystroke")

        // The last injected record is `later`; the pasteboard holds its text.
        XCTAssertEqual(pasteboard.string(forType: .string), "later")

        // Frequency: good and later bumped; bad did not.
        let metas = try runtime.history(limit: 10, query: "")
        let byID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0.meta.frequency) })
        XCTAssertEqual(byID[good.id], 1)
        XCTAssertEqual(byID[later.id], 1)
        XCTAssertEqual(byID[bad.id], 0, "the malformed record must not bump frequency")
    }

    func testPasteQueuedMissingRecordIsExplicitlyUnavailableAndContinues() throws {
        let good = try runtime.appendTestRecord(.text("good"))
        // A record id that was never appended: body(for:) throws recordNotFound.
        let missing = RecordID.generate()
        let later = try runtime.appendTestRecord(.text("later"))

        let result = try runtime.pasteQueued(ids: [good.id, missing, later.id])

        guard case let .completed(injectedIDs, unavailableIDs, unavailableKinds) = result else {
            XCTFail("expected .completed, got \(result)")
            return
        }
        XCTAssertEqual(injectedIDs, [good.id, later.id], "good and later must be injected; missing must not")
        XCTAssertEqual(unavailableIDs, [missing], "the missing record must be explicitly unavailable")
        XCTAssertEqual(unavailableKinds, [.unsupported], "a body that cannot be read reports .unsupported")

        XCTAssertEqual(postedEventCount, 2, "the missing record must not post a paste keystroke")
        XCTAssertEqual(pasteboard.string(forType: .string), "later")

        let metas = try runtime.history(limit: 10, query: "")
        let byID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0.meta.frequency) })
        XCTAssertEqual(byID[good.id], 1)
        XCTAssertEqual(byID[later.id], 1)
    }

    // MARK: - Runtime: untrusted / manual-stop behavior

    func testPasteQueuedManualPasteRequiredStopsWithCurrentAndRemainingAndNoExtraEvents() throws {
        // Build a trusted runtime first so the first record injects, then
        // switch the injector to manualPasteRequired for the second record to
        // simulate Accessibility becoming unavailable mid-queue.
        _ = try runtime.appendTestRecord(.text("first"))
        _ = try runtime.appendTestRecord(.text("second"))
        _ = try runtime.appendTestRecord(.text("third"))

        // Recreate the runtime with an injector that returns manualPasteRequired
        // for the second and third records (trusted for the first only). We do
        // this by toggling a flag inside postEvents is too late (inject already
        // returned injected), so instead use a custom isProcessTrusted that
        // flips to false after the first successful prepare.
        var trusted = true
        let paths = try MacClippyPaths(rootURL: tempRoot)
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { trusted },
            postEvents: { [weak self] _, _ in
                self?.postedEventCount &+= 1
            }
        )
        let flippingRuntime = try MacClippyRuntime(paths: paths, pasteInjector: injector)
        _ = try flippingRuntime.appendTestRecord(.text("first-dup"))

        // We want a clean store for the flip test; reuse the original runtime's
        // records by recreating them in the flipping runtime's store. Simpler:
        // perform the whole test against flippingRuntime with its own records.
        let f1 = try flippingRuntime.appendTestRecord(.text("first"))
        let f2 = try flippingRuntime.appendTestRecord(.text("second"))
        let f3 = try flippingRuntime.appendTestRecord(.text("third"))

        // Flip trust to false BEFORE calling pasteQueued so the very first
        // inject returns manualPasteRequired and we can assert the stop shape
        // cleanly (current = first, remaining = first..third).
        trusted = false
        let result = try flippingRuntime.pasteQueued(ids: [f1.id, f2.id, f3.id])

        guard case let .manualPasteRequired(injectedIDs, unavailableIDs, _, manualID, remainingIDs) = result else {
            XCTFail("expected .manualPasteRequired when untrusted, got \(result)")
            return
        }
        XCTAssertTrue(injectedIDs.isEmpty, "no record should be claimed injected on a manual stop at the first record")
        XCTAssertTrue(unavailableIDs.isEmpty, "no record should be unavailable before a first-record manual stop")
        XCTAssertEqual(manualID, f1.id, "the manual-paste id must be the current (first) record")
        XCTAssertEqual(remainingIDs, [f1.id, f2.id, f3.id], "remaining must be the current id plus every not-yet-attempted id")

        // No events posted because the injector never reached postEvents.
        XCTAssertEqual(postedEventCount, 0, "a manual stop must not post any paste keystroke")

        // No frequency bumps on a manual stop at the first record.
        let metas = try flippingRuntime.history(limit: 10, query: "")
        let byID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0.meta.frequency) })
        XCTAssertEqual(byID[f1.id], 0)
        XCTAssertEqual(byID[f2.id], 0)
        XCTAssertEqual(byID[f3.id], 0)
    }

    func testPasteQueuedManualPasteRequiredMidQueueStopsAndReportsRemaining() throws {
        // First record injects (trusted), then trust flips off so the second
        // record returns manualPasteRequired. The queue must stop with the
        // current id = second and remaining = second..last, and no further
        // events may be posted.
        var trusted = true
        let paths = try MacClippyPaths(rootURL: tempRoot)
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { trusted },
            postEvents: { [weak self] _, _ in
                self?.postedEventCount &+= 1
                // Flip trust off AFTER the first successful post so the next
                // inject returns manualPasteRequired.
                trusted = false
            }
        )
        let flippingRuntime = try MacClippyRuntime(paths: paths, pasteInjector: injector)
        let first = try flippingRuntime.appendTestRecord(.text("first"))
        let second = try flippingRuntime.appendTestRecord(.text("second"))
        let third = try flippingRuntime.appendTestRecord(.text("third"))

        let result = try flippingRuntime.pasteQueued(ids: [first.id, second.id, third.id])

        guard case let .manualPasteRequired(injectedIDs, unavailableIDs, unavailableKinds, manualID, remainingIDs) = result else {
            XCTFail("expected .manualPasteRequired mid-queue, got \(result)")
            return
        }
        XCTAssertEqual(injectedIDs, [first.id], "the first record was injected before the manual stop")
        XCTAssertTrue(unavailableIDs.isEmpty)
        XCTAssertTrue(unavailableKinds.isEmpty)
        XCTAssertEqual(manualID, second.id, "the manual-paste id must be the current (second) record")
        XCTAssertEqual(remainingIDs, [second.id, third.id], "remaining must be the current id plus every not-yet-attempted id")

        // Exactly one event (the first record); the manual stop posted none.
        XCTAssertEqual(postedEventCount, 1, "only the first record may post a paste keystroke")

        // Frequency bumped only for the injected first record.
        let metas = try flippingRuntime.history(limit: 10, query: "")
        let byID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0.meta.frequency) })
        XCTAssertEqual(byID[first.id], 1)
        XCTAssertEqual(byID[second.id], 0, "the manual-stop record must not bump frequency")
        XCTAssertEqual(byID[third.id], 0, "the not-yet-attempted record must not bump frequency")
    }

    // MARK: - Dock model: feedback and stale-completion behavior

    @MainActor
    func testModelPasteQueuedFullSuccessClosesDockAndShowsCompletedFeedback() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("first"))
        _ = try runtime.appendTestRecord(.text("second"))
        model.reload()
        wait { model.historyItems.count >= 2 }

        model.beginSession()
        model.selectAllVisible()
        XCTAssertTrue(model.hasMultipleSelection)
        var didClose = false
        model.pasteQueued(completion: { didClose = true })

        // Two records => two posted events. Wait for the main-thread result
        // before asserting the close callback; the second event can arrive
        // just before the queue completion is dispatched to the main actor.
        wait { didClose || model.actionFeedback != nil || model.errorMessage != nil }

        XCTAssertTrue(didClose, "full queue success should close the dock")
        guard case let .queuePasteCompleted(injectedCount, unavailableCount) = model.actionFeedback else {
            XCTFail("expected .queuePasteCompleted, got \(String(describing: model.actionFeedback))")
            return
        }
        XCTAssertEqual(injectedCount, 2)
        XCTAssertEqual(unavailableCount, 0)
        XCTAssertEqual(postedEventCount, 2)
    }

    @MainActor
    func testModelPasteQueuedPartialCompletionKeepsDockOpenAndShowsPartialFeedback() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("good"))
        let malformedRTF = Data("{\\rtf1 THIS IS NOT VALID RTF".utf8)
        _ = try runtime.appendTestRecord(.rtf(malformedRTF))
        _ = try runtime.appendTestRecord(.text("later"))
        model.reload()
        wait { model.historyItems.count >= 3 }

        model.beginSession()
        model.selectAllVisible()
        XCTAssertTrue(model.hasMultipleSelection)
        var didClose = false
        model.pasteQueued(completion: { didClose = true })

        wait { model.actionFeedback != nil || model.errorMessage != nil }

        XCTAssertFalse(didClose, "partial queue completion must keep the dock open")
        guard case let .queuePastePartial(injectedCount, unavailableCount, unavailableKinds) = model.actionFeedback else {
            XCTFail("expected .queuePastePartial, got \(String(describing: model.actionFeedback))")
            return
        }
        XCTAssertEqual(injectedCount, 2, "good and later must be injected")
        XCTAssertEqual(unavailableCount, 1, "the malformed RTF must be reported unavailable")
        XCTAssertEqual(unavailableKinds, [.rtf])
        // Two injections (good + later); the malformed record did not post.
        XCTAssertEqual(postedEventCount, 2)
    }

    @MainActor
    func testModelPasteQueuedManualStopKeepsDockOpenAndShowsManualStopFeedback() throws {
        // Untrusted injector => manualPasteRequired at the first record.
        let trusted = false
        let paths = try MacClippyPaths(rootURL: tempRoot)
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { trusted },
            postEvents: { [weak self] _, _ in
                self?.postedEventCount &+= 1
            }
        )
        let untrustedRuntime = try MacClippyRuntime(paths: paths, pasteInjector: injector)
        _ = try untrustedRuntime.appendTestRecord(.text("first"))
        _ = try untrustedRuntime.appendTestRecord(.text("second"))

        let model = MacClippyDockModel(runtime: untrustedRuntime)
        model.reload()
        wait { model.historyItems.count >= 2 }

        model.beginSession()
        model.selectAllVisible()
        XCTAssertTrue(model.hasMultipleSelection)
        var didClose = false
        model.pasteQueued(completion: { didClose = true })

        wait { model.actionFeedback != nil || model.errorMessage != nil }

        XCTAssertFalse(didClose, "a manual-paste stop must keep the dock open")
        guard case let .queuePasteManualStop(injectedCount, remainingCount) = model.actionFeedback else {
            XCTFail("expected .queuePasteManualStop, got \(String(describing: model.actionFeedback))")
            return
        }
        XCTAssertEqual(injectedCount, 0, "no record is injected on a first-record manual stop")
        XCTAssertEqual(remainingCount, 2, "both selected ids remain unconsumed")
        XCTAssertEqual(postedEventCount, 0, "a manual stop must not post any paste keystroke")

        // The model retains this secondary runtime until it is deallocated.
        // Close it before teardown removes the shared temporary root so WAL/
        // SHM files are not unlinked while GRDB still owns their descriptors.
        untrustedRuntime.closeForTesting()
    }

    @MainActor
    func testModelPasteQueuedSingleSelectionFallsBackToPasteFocused() throws {
        // A single selection routes through pasteFocused, not the queue path.
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("only"))
        model.reload()
        wait { model.historyItems.count >= 1 }

        model.focusSelection(at: 0)
        XCTAssertFalse(model.hasMultipleSelection)

        model.beginSession()
        var didClose = false
        model.pasteQueued(completion: { didClose = true })

        wait { didClose || model.actionFeedback != nil || model.errorMessage != nil }

        XCTAssertTrue(didClose, "single-selection queue paste should fall back to pasteFocused and close")
        // pasteFocused posts exactly one event.
        XCTAssertEqual(postedEventCount, 1)
        guard case let .pasted(manual) = model.actionFeedback else {
            XCTFail("expected .pasted feedback for the single-selection fallback, got \(String(describing: model.actionFeedback))")
            return
        }
        XCTAssertFalse(manual)
    }

    @MainActor
    func testModelPasteQueuedStaleCompletionDoesNotCloseReopenedDock() throws {
        // Session-generation guard must hold for queue paste: a stale
        // completion from a previous dock session must not call the close
        // handler or mutate a newly reopened dock.
        let model = MacClippyDockModel(runtime: runtime)
        // Capture the two appended record IDs so the drain below can wait
        // deterministically on the store state rather than on a main-thread
        // completion that the generation guard will suppress.
        let firstMeta = try runtime.appendTestRecord(.text("first"))
        let secondMeta = try runtime.appendTestRecord(.text("second"))
        model.reload()
        wait { model.historyItems.count >= 2 }

        model.beginSession()
        model.selectAllVisible()
        XCTAssertTrue(model.hasMultipleSelection)
        var didClose = false
        model.pasteQueued(completion: { didClose = true })

        // End the session (hide) and start a new one (reopen) before the work
        // queue drains. The stale completion must be suppressed.
        model.endSession()
        model.beginSession()

        wait { postedEventCount > 0 || model.actionFeedback != nil || model.errorMessage != nil || didClose }

        XCTAssertFalse(didClose, "stale queue-paste completion must not close a reopened dock")

        // The stale-completion assertion is the point of this test, but the
        // work-queue block is still in flight here: pasteQueued injects one
        // Cmd+V per record with a Thread.sleep settle between injections, and
        // only then dispatches the (generation-suppressed) completion back to
        // main. Ending the test after the first posted event lets teardown
        // delete the temp DB directory while that block still holds open SQLite
        // connections, which libsqlite3 flags as "vnode unlinked while in use".
        //
        // Drain the intentionally stale queue operation deterministically
        // before teardown. The suppressed main completion can never set
        // actionFeedback/errorMessage/didClose (the reopened dock's session
        // generation no longer matches), so waiting on those would always burn
        // the full timeout. Instead wait for proof that pasteQueued finished
        // its final store update: the second record's frequency bumps to 1
        // (bumpFrequency runs under the store lock only after the second
        // .injected) alongside the second posted event. The runloop spin inside
        // wait processes the generation-suppressed main dispatch during the
        // wait. didClose stays false because the session-generation guard
        // suppresses the stale completion, so the assertion above is not
        // weakened.
        wait {
            postedEventCount >= 2
                && (try? runtime.history(limit: 10, query: ""))?
                    .first { $0.id == secondMeta.id }?.meta.frequency == 1
        }
        // Both records bumped to 1: deterministic proof the queue drained every
        // store update before teardown (uses both captured metas).
        let metas = try runtime.history(limit: 10, query: "")
        let byID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0.meta.frequency) })
        XCTAssertEqual(byID[firstMeta.id], 1, "the first record must bump frequency once the queue drains")
        XCTAssertEqual(byID[secondMeta.id], 1, "the second record must bump frequency once the queue drains")
        XCTAssertFalse(didClose, "stale queue-paste completion must not close a reopened dock")
    }

    // MARK: - Helpers

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
