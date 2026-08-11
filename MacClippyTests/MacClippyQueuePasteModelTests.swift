import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

// Focused DockModel tests for queue-paste feedback and session-generation
// behavior. Runtime queue-paste semantics remain in MacClippyQueuePasteTests.
final class MacClippyQueuePasteModelTests: XCTestCase {
    private var tempRoot: URL!
    private var pasteboard: NSPasteboard!
    private var postedEventCount: Int = 0
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyQueuePasteModelTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyQueuePasteModel-\(UUID().uuidString)"))
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

        // Wait for the main-thread result before asserting the close callback;
        // the second event can arrive just before the completion dispatch.
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
        guard case let .queuePastePartial(injectedCount, unavailableCount, unavailableKinds) =
            model.actionFeedback else {
            XCTFail("expected .queuePastePartial, got \(String(describing: model.actionFeedback))")
            return
        }
        XCTAssertEqual(injectedCount, 2, "good and later must be injected")
        XCTAssertEqual(unavailableCount, 1, "the malformed RTF must be reported unavailable")
        XCTAssertEqual(unavailableKinds, [.rtf])
        XCTAssertEqual(postedEventCount, 2)
    }

    @MainActor
    func testModelPasteQueuedManualStopKeepsDockOpenAndShowsManualStopFeedback() throws {
        // An untrusted injector returns manualPasteRequired at the first record.
        let paths = try MacClippyPaths(rootURL: tempRoot)
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { false },
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

        // Close the secondary runtime before teardown removes the shared root.
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
        XCTAssertEqual(postedEventCount, 1)
        guard case let .pasted(manual) = model.actionFeedback else {
            let feedback = String(describing: model.actionFeedback)
            XCTFail("expected .pasted feedback for the single-selection fallback, got \(feedback)")
            return
        }
        XCTAssertFalse(manual)
    }

    @MainActor
    func testModelPasteQueuedStaleCompletionDoesNotCloseReopenedDock() throws {
        // A stale completion from a previous dock session must not close or
        // mutate a newly reopened dock.
        let model = MacClippyDockModel(runtime: runtime)
        let firstMeta = try runtime.appendTestRecord(.text("first"))
        let secondMeta = try runtime.appendTestRecord(.text("second"))
        model.reload()
        wait { model.historyItems.count >= 2 }

        model.beginSession()
        model.selectAllVisible()
        XCTAssertTrue(model.hasMultipleSelection)
        var didClose = false
        model.pasteQueued(completion: { didClose = true })

        model.endSession()
        model.beginSession()
        model.workQueue.sync {}

        XCTAssertFalse(didClose, "stale queue-paste completion must not close a reopened dock")
        XCTAssertEqual(postedEventCount, 0)
        let metas = try runtime.history(limit: 10, query: "")
        let byID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0.meta.frequency) })
        XCTAssertEqual(byID[firstMeta.id], 0, "the cancelled queue must not bump the first record")
        XCTAssertEqual(byID[secondMeta.id], 0, "the cancelled queue must not bump the second record")
        XCTAssertFalse(didClose, "stale queue-paste completion must not close a reopened dock")
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
