import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

// P1 regression tests for the Copy all path. Copy all must prepare the merged
// homogeneous text on NSPasteboard.general (or the injector's pasteboard)
// WITHOUT injecting any keyboard event, while preserving the existing mixed-
// selection and unavailable-payload no-silent-data-loss behavior and the
// session/operation generation guards. These tests use a recording injector
// whose `postEvents` closure counts every paste keystroke, so a regression
// that routes Copy all through `inject` (which posts Cmd+V) is caught directly.
final class MacClippyCopyAllTests: XCTestCase {
    private var tempRoot: URL!
    private var pasteboard: NSPasteboard!
    private var postedEventCount: Int = 0
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyCopyAllTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // A named pasteboard isolates the test from NSPasteboard.general and
        // from any other test running concurrently. The recording injector
        // writes here and the assertions read here.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyCopyAll-\(UUID().uuidString)"))
        postedEventCount = 0

        let paths = try MacClippyPaths(rootURL: tempRoot)
        // Custom injector: trusted so `inject` would proceed to post events if
        // it were ever called; the postEvents closure counts posts so a
        // regression that routes Copy all through inject is observable. There
        // is no writeSentinel here because the runtime is never started (the
        // observer never polls), so recapture suppression is irrelevant.
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

    // MARK: - Runtime copyOrdered

    func testCopyOrderedPreparesMergedTextAndDoesNotPostPasteKeystroke() throws {
        let first = try runtime.appendTestRecord(.text("alpha"))
        let second = try runtime.appendTestRecord(.text("beta"))

        let result = try runtime.copyOrdered(ids: [second.id, first.id])
        guard case let .merged(prepared) = result else {
            XCTFail("expected .merged for a homogeneous text selection, got \(result)")
            return
        }

        // The pasteboard must hold the merged text in visual order.
        XCTAssertTrue(prepared)
        XCTAssertEqual(pasteboard.string(forType: .string), "beta\nalpha")
        // The P1 invariant: Copy all must never post a paste keystroke.
        XCTAssertEqual(postedEventCount, 0, "copyOrdered must not post a paste keystroke")
    }

    func testCopyOrderedWithMixedSelectionDoesNotPreparePasteboardAndDoesNotPost() throws {
        let text = try runtime.appendTestRecord(.text("text"))
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))

        let result = try runtime.copyOrdered(ids: [text.id, image.id])
        guard case let .mixed(supportedIDs, unsupportedIDs, unsupportedKinds) = result else {
            XCTFail("expected .mixed for a text+image selection, got \(result)")
            return
        }
        XCTAssertEqual(supportedIDs, [text.id])
        XCTAssertEqual(unsupportedIDs, [image.id])
        XCTAssertEqual(unsupportedKinds, [.image])

        // No subset is prepared: the pasteboard string must be nil (nothing
        // written) and no keystroke is posted.
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(postedEventCount, 0)
    }

    func testCopyOrderedWithMalformedRTFReportsUnavailableAndDoesNotPrepareOrPost() throws {
        let good = try runtime.appendTestRecord(.text("good"))
        let malformedRTF = Data("{\\rtf1 THIS IS NOT VALID RTF".utf8)
        let bad = try runtime.appendTestRecord(.rtf(malformedRTF))

        let result = try runtime.copyOrdered(ids: [good.id, bad.id])
        guard case let .textUnavailable(availableIDs, unavailableIDs, unavailableKinds) = result else {
            XCTFail("expected .textUnavailable for a text+malformed-rtf selection, got \(result)")
            return
        }
        XCTAssertEqual(availableIDs, [good.id])
        XCTAssertEqual(unavailableIDs, [bad.id])
        XCTAssertEqual(unavailableKinds, [.rtf])

        // No pasteboard write, no keystroke: an unavailable payload must never
        // be silently merged as an empty piece.
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(postedEventCount, 0)
    }

    func testCopyOrderedWithEmptyRealTextMergesEmptyPieceAndDoesNotPost() throws {
        // An empty real text payload ("") is a valid empty piece and must be
        // merged in visual order; it is NOT reported as unavailable, and no
        // paste keystroke is posted.
        let a = try runtime.appendTestRecord(.text("alpha"))
        let empty = try runtime.appendTestRecord(.text(""))

        let result = try runtime.copyOrdered(ids: [a.id, empty.id])
        guard case .merged = result else {
            XCTFail("expected .merged for a text selection with one empty real text, got \(result)")
            return
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "alpha\n")
        XCTAssertEqual(postedEventCount, 0)
    }

    func testCopyOrderedDoesNotBumpFrequency() throws {
        // Copy never bumps frequency (matching the single copy(id:) path);
        // only paste bumps frequency. Guards against a regression that shares
        // the pasteOrdered bump loop.
        let first = try runtime.appendTestRecord(.text("alpha"))
        let second = try runtime.appendTestRecord(.text("beta"))

        _ = try runtime.copyOrdered(ids: [second.id, first.id])

        let metas = try runtime.history(limit: 10, query: "")
        let firstMeta = metas.first(where: { $0.id == first.id })
        let secondMeta = metas.first(where: { $0.id == second.id })
        XCTAssertEqual(firstMeta?.meta.frequency, 0, "copyOrdered must not bump frequency")
        XCTAssertEqual(secondMeta?.meta.frequency, 0, "copyOrdered must not bump frequency")
    }

    // MARK: - Paste all still posts (negative guard)

    func testPasteOrderedStillPostsPasteKeystrokeForMergedText() throws {
        // Negative guard: pasteOrdered must continue to post a paste keystroke
        // for a homogeneous text selection. This confirms the recording
        // injector is wired correctly and that the Copy-all fix did not
        // accidentally neutralize the Paste-all path.
        let first = try runtime.appendTestRecord(.text("alpha"))
        let second = try runtime.appendTestRecord(.text("beta"))

        let result = try runtime.pasteOrdered(ids: [second.id, first.id])
        guard case let .merged(injected) = result else {
            XCTFail("expected .merged for pasteOrdered, got \(result)")
            return
        }
        XCTAssertTrue(injected, "pasteOrdered should inject the paste keystroke when trusted")
        XCTAssertEqual(postedEventCount, 1, "pasteOrdered posts exactly one paste keystroke")
        XCTAssertEqual(pasteboard.string(forType: .string), "beta\nalpha")
    }

    // MARK: - Dock model copySelectedAll

    @MainActor
    func testCopySelectedAllPreparesPasteboardAndDoesNotPostKeystroke() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("first"))
        _ = try runtime.appendTestRecord(.text("second"))
        model.reload()
        wait { model.historyItems.count >= 2 }

        model.beginSession()
        model.selectAllVisible()
        XCTAssertTrue(model.hasMultipleSelection)
        model.copySelectedAll()

        // Wait for the work queue to drain and the copied feedback to appear.
        wait { model.actionFeedback != nil }

        // The dock must report copied feedback, not mixed/unavailable.
        guard case .copied = model.actionFeedback else {
            XCTFail("expected .copied feedback for Copy all, got \(String(describing: model.actionFeedback))")
            return
        }
        // The merged text is on the pasteboard in visual (newest-first) order.
        XCTAssertEqual(pasteboard.string(forType: .string), "second\nfirst")
        // The P1 invariant: Copy all must never post a paste keystroke.
        XCTAssertEqual(postedEventCount, 0, "copySelectedAll must not post a paste keystroke")
    }

    @MainActor
    func testCopySelectedAllWithMixedSelectionShowsMixedFeedbackAndDoesNotPost() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("text"))
        _ = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))
        model.reload()
        wait { model.historyItems.count >= 2 }

        model.beginSession()
        model.selectAllVisible()
        XCTAssertTrue(model.hasMultipleSelection)
        model.copySelectedAll()

        wait { model.actionFeedback != nil }

        guard case let .multiPasteMixed(supportedCount, unsupportedCount, _) = model.actionFeedback else {
            XCTFail("expected .multiPasteMixed feedback, got \(String(describing: model.actionFeedback))")
            return
        }
        XCTAssertEqual(supportedCount, 1)
        XCTAssertEqual(unsupportedCount, 1)
        // No subset is prepared and no keystroke is posted.
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(postedEventCount, 0)
    }

    @MainActor
    func testCopySelectedAllStaleCompletionDoesNotMutateReopenedDock() throws {
        // Session/operation generation guards must still hold for Copy all: a
        // stale completion from a previous dock session must not show feedback
        // on a newly reopened dock.
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("first"))
        _ = try runtime.appendTestRecord(.text("second"))
        model.reload()
        wait { model.historyItems.count >= 2 }

        model.beginSession()
        model.selectAllVisible()
        model.copySelectedAll()

        // End the session (hide) and start a new one (reopen) before the work
        // queue drains. The stale completion must be suppressed.
        model.endSession()
        model.beginSession()

        wait { postedEventCount > 0 || model.actionFeedback != nil }

        XCTAssertNil(model.actionFeedback, "stale Copy-all completion must not show feedback on a reopened dock")
        XCTAssertEqual(postedEventCount, 0, "Copy all must not post a paste keystroke even on a stale completion")
    }

    @MainActor
    func testCopySelectedAllFallsBackToCopyFocusedForSingleSelection() throws {
        // A single selection (or none) routes through copyFocused, not the
        // multi-copy path. This test guards that the guard clause is preserved
        // and Copy all with one record still does not post a keystroke.
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("only"))
        model.reload()
        wait { model.historyItems.count >= 1 }

        model.focusSelection(at: 0)
        XCTAssertFalse(model.hasMultipleSelection)

        model.beginSession()
        model.copySelectedAll()

        wait { model.actionFeedback != nil }

        guard case .copied = model.actionFeedback else {
            XCTFail("expected .copied feedback for single Copy all, got \(String(describing: model.actionFeedback))")
            return
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "only")
        XCTAssertEqual(postedEventCount, 0)
    }

    @MainActor
    func testCopyFocusedInvokesCompletionAfterSuccessfulCopy() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("copy and close"))
        model.reload()
        wait { model.historyItems.count == 1 }

        model.focusSelection(at: 0)
        var completionCalled = false
        model.copyFocused(plain: false, completion: {
            completionCalled = true
        })

        wait { completionCalled }

        XCTAssertTrue(completionCalled)
        XCTAssertEqual(pasteboard.string(forType: .string), "copy and close")
    }

    // MARK: - Helpers

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
