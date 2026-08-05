import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

// Focused tests for the transformed copy/paste feature. The transform engine
// (MacClippyTextTransform) operates on plain text; html/rtf records are
// converted to plain text via the existing MacClippyClipboardText path before
// the transform is applied, and image/files records are rejected explicitly so
// they are never silently transformed or dropped. Transformed copy must only
// prepare the pasteboard and never post Cmd+V; transformed paste must inject
// Cmd+V and bump frequency only on a successful injection, matching the
// existing copy(id:plain:)/paste(id:) semantics. These tests use a recording
// injector whose postEvents closure counts every paste keystroke, mirroring
// MacClippyCopyAllTests, so a regression that routes transformed copy through
// inject (which posts Cmd+V) is caught directly.
final class MacClippyTransformTests: XCTestCase {
    private var tempRoot: URL!
    private var pasteboard: NSPasteboard!
    private var postedEventCount: Int = 0
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyTransformTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // A named pasteboard isolates the test from NSPasteboard.general and
        // from any other test running concurrently. The recording injector
        // writes here and the assertions read here.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyTransform-\(UUID().uuidString)"))
        postedEventCount = 0

        let paths = try MacClippyPaths(rootURL: tempRoot)
        // Custom injector: trusted so `inject` proceeds to post events; the
        // postEvents closure counts posts so a regression that routes
        // transformed copy through inject is observable. No writeSentinel is
        // needed because the runtime is never started (the observer never
        // polls), so recapture suppression is irrelevant here.
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

    // MARK: - Runtime: transformed copy

    func testCopyTransformedWritesExpectedTextAndDoesNotPostPasteKeystroke() throws {
        let meta = try runtime.appendTestRecord(.text("hello world"))

        let prepared = try runtime.copy(id: meta.id, transform: .uppercase)

        XCTAssertTrue(prepared, "copy(id:transform:) should prepare the pasteboard")
        XCTAssertEqual(pasteboard.string(forType: .string), "HELLO WORLD")
        // The core invariant: transformed copy must never post a paste keystroke.
        XCTAssertEqual(postedEventCount, 0, "copy(id:transform:) must not post a paste keystroke")
    }

    func testCopyTransformedAppliesEveryTransform() throws {
        // One record per transform so each assertion is independent; the
        // pasteboard is shared but each copy overwrites it.
        let upper = try runtime.appendTestRecord(.text("abc"))
        XCTAssertTrue(try runtime.copy(id: upper.id, transform: .uppercase))
        XCTAssertEqual(pasteboard.string(forType: .string), "ABC")

        let lower = try runtime.appendTestRecord(.text("ABC"))
        XCTAssertTrue(try runtime.copy(id: lower.id, transform: .lowercase))
        XCTAssertEqual(pasteboard.string(forType: .string), "abc")

        let trimmed = try runtime.appendTestRecord(.text("  hi \n"))
        XCTAssertTrue(try runtime.copy(id: trimmed.id, transform: .trim))
        XCTAssertEqual(pasteboard.string(forType: .string), "hi")

        let json = try runtime.appendTestRecord(.text("{\"b\":2,\"a\":1}"))
        XCTAssertTrue(try runtime.copy(id: json.id, transform: .prettyJSON))
        XCTAssertEqual(pasteboard.string(forType: .string), "{\n  \"a\" : 1,\n  \"b\" : 2\n}")

        let url = try runtime.appendTestRecord(.text("https://example.com?utm_medium=x&a=1"))
        XCTAssertTrue(try runtime.copy(id: url.id, transform: .cleanTrackingURL))
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com?a=1")

        XCTAssertEqual(postedEventCount, 0, "no transform copy may post a paste keystroke")
    }

    func testCopyTransformedHtmlDerivesPlainTextBeforeTransform() throws {
        // HTML transforms intentionally produce plain text: the transform
        // engine operates on text, so the html is converted to plain text via
        // the existing MacClippyClipboardText path before the transform runs.
        let html = try runtime.appendTestRecord(.html("<p>hello <b>world</b></p>"))

        XCTAssertTrue(try runtime.copy(id: html.id, transform: .uppercase))
        // The pasteboard carries the transformed plain text, not transformed
        // markup.
        let value = pasteboard.string(forType: .string)
        XCTAssertEqual(value?.uppercased(), value, "html transform must operate on plain text")
        XCTAssertTrue(value?.contains("HELLO") == true || value?.contains("WORLD") == true,
                      "html plain text should contain the uppercased words; got \(value ?? "nil")")
        XCTAssertEqual(postedEventCount, 0)
    }

    func testCopyTransformedRtfDerivesPlainTextBeforeTransform() throws {
        // Build a minimal valid RTF document carrying "hello" so the plain-
        // text derivation succeeds, then assert the transform is applied to
        // the derived plain text.
        let rtf = minimalRTF(carrying: "hello")
        let record = try runtime.appendTestRecord(.rtf(rtf))

        XCTAssertTrue(try runtime.copy(id: record.id, transform: .uppercase))
        XCTAssertEqual(pasteboard.string(forType: .string), "HELLO")
        XCTAssertEqual(postedEventCount, 0)
    }

    func testCopyTransformedImageRejectsExplicitlyAndDoesNotPrepareOrPost() throws {
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))

        XCTAssertThrowsError(try runtime.copy(id: image.id, transform: .uppercase)) { error in
            // The explicit reject reuses the existing invalidStoredRecord
            // error so the dock surfaces it instead of silently dropping.
            guard case MacClippyStoreError.invalidStoredRecord = error else {
                XCTFail("expected invalidStoredRecord for an image transform, got \(error)")
                return
            }
        }
        XCTAssertNil(pasteboard.string(forType: .string), "image must not be silently transformed onto the pasteboard")
        XCTAssertEqual(postedEventCount, 0)
    }

    func testCopyTransformedFilesRejectExplicitlyAndDoesNotPrepareOrPost() throws {
        let files = try runtime.appendTestRecord(.files([URL(fileURLWithPath: "/tmp/a.txt")]))

        XCTAssertThrowsError(try runtime.copy(id: files.id, transform: .lowercase)) { error in
            guard case MacClippyStoreError.invalidStoredRecord = error else {
                XCTFail("expected invalidStoredRecord for a files transform, got \(error)")
                return
            }
        }
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(postedEventCount, 0)
    }

    func testCopyTransformedMalformedRTFReportsErrorAndDoesNotPrepareOrPost() throws {
        // Malformed RTF cannot yield plain text; the runtime must report an
        // error instead of silently producing an empty/transformed string.
        let malformedRTF = Data("{\\rtf1 THIS IS NOT VALID RTF".utf8)
        let bad = try runtime.appendTestRecord(.rtf(malformedRTF))

        XCTAssertThrowsError(try runtime.copy(id: bad.id, transform: .uppercase)) { error in
            guard case MacClippyStoreError.invalidStoredRecord = error else {
                XCTFail("expected invalidStoredRecord for malformed rtf, got \(error)")
                return
            }
        }
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(postedEventCount, 0)
    }

    func testCopyTransformedDoesNotBumpFrequency() throws {
        // Copy never bumps frequency (matching copy(id:plain:)); only paste
        // bumps frequency. Guards against a regression that shares the paste
        // bump path.
        let meta = try runtime.appendTestRecord(.text("alpha"))

        _ = try runtime.copy(id: meta.id, transform: .uppercase)

        let metas = try runtime.history(limit: 10, query: "")
        let updated = metas.first(where: { $0.id == meta.id })
        XCTAssertEqual(updated?.meta.frequency, 0, "copy(id:transform:) must not bump frequency")
    }

    // MARK: - Runtime: transformed paste

    func testPasteTransformedWritesExpectedTextAndPostsOnce() throws {
        let meta = try runtime.appendTestRecord(.text("hello world"))

        let result = try runtime.paste(id: meta.id, transform: .uppercase)

        XCTAssertEqual(result, .injected, "paste(id:transform:) should inject when trusted")
        XCTAssertEqual(pasteboard.string(forType: .string), "HELLO WORLD")
        // Transformed paste posts exactly one paste keystroke, matching
        // paste(id:).
        XCTAssertEqual(postedEventCount, 1, "paste(id:transform:) must post exactly one paste keystroke")
    }

    func testPasteTransformedBumpsFrequencyOnlyOnSuccessfulInjection() throws {
        let meta = try runtime.appendTestRecord(.text("alpha"))

        let result = try runtime.paste(id: meta.id, transform: .lowercase)
        XCTAssertEqual(result, .injected)

        let metas = try runtime.history(limit: 10, query: "")
        let updated = metas.first(where: { $0.id == meta.id })
        XCTAssertEqual(updated?.meta.frequency, 1, "paste(id:transform:) must bump frequency on injection")
    }

    func testPasteTransformedImageRejectsExplicitlyDoesNotPostOrBumpFrequency() throws {
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))

        XCTAssertThrowsError(try runtime.paste(id: image.id, transform: .uppercase)) { error in
            guard case MacClippyStoreError.invalidStoredRecord = error else {
                XCTFail("expected invalidStoredRecord for an image paste transform, got \(error)")
                return
            }
        }
        XCTAssertEqual(postedEventCount, 0, "a rejected transform must not post a paste keystroke")
        XCTAssertNil(pasteboard.string(forType: .string))

        // Frequency must not be bumped when the transform was rejected.
        let metas = try runtime.history(limit: 10, query: "")
        let updated = metas.first(where: { $0.id == image.id })
        XCTAssertEqual(updated?.meta.frequency, 0, "a rejected paste transform must not bump frequency")
    }

    func testPasteTransformedMalformedRTFReportsErrorDoesNotPostOrBump() throws {
        let malformedRTF = Data("{\\rtf1 THIS IS NOT VALID RTF".utf8)
        let bad = try runtime.appendTestRecord(.rtf(malformedRTF))

        XCTAssertThrowsError(try runtime.paste(id: bad.id, transform: .uppercase)) { error in
            guard case MacClippyStoreError.invalidStoredRecord = error else {
                XCTFail("expected invalidStoredRecord for malformed rtf paste, got \(error)")
                return
            }
        }
        XCTAssertEqual(postedEventCount, 0)
        XCTAssertNil(pasteboard.string(forType: .string))

        let metas = try runtime.history(limit: 10, query: "")
        let updated = metas.first(where: { $0.id == bad.id })
        XCTAssertEqual(updated?.meta.frequency, 0, "a malformed rtf paste must not bump frequency")
    }

    // MARK: - Dock model: context-facing paths preserve async behavior

    @MainActor
    func testModelCopyFocusedTransformedPreparesPasteboardAndDoesNotPost() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("hello"))
        model.reload()
        wait { model.historyItems.count >= 1 }

        model.focusSelection(at: 0)
        model.beginSession()
        model.copyFocused(transform: .uppercase)

        wait { model.actionFeedback != nil }

        guard case let .transformedCopied(name) = model.actionFeedback else {
            XCTFail("expected .transformedCopied feedback, got \(String(describing: model.actionFeedback))")
            return
        }
        XCTAssertEqual(name, "Uppercase")
        XCTAssertEqual(pasteboard.string(forType: .string), "HELLO")
        XCTAssertEqual(postedEventCount, 0, "model copy transform must not post a paste keystroke")
    }

    @MainActor
    func testModelPasteFocusedTransformedPostsOnceAndClosesDock() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("hello"))
        model.reload()
        wait { model.historyItems.count >= 1 }

        model.focusSelection(at: 0)
        model.beginSession()

        var didClose = false
        model.pasteFocused(transform: .uppercase, completion: { didClose = true })

        wait { didClose || model.actionFeedback != nil || model.errorMessage != nil }

        XCTAssertTrue(didClose, "transformed paste should close the dock on success")
        guard case let .transformedPasted(name, manual) = model.actionFeedback else {
            XCTFail("expected .transformedPasted feedback, got \(String(describing: model.actionFeedback))")
            return
        }
        XCTAssertEqual(name, "Uppercase")
        XCTAssertFalse(manual, "trusted injector should report an injected paste")
        XCTAssertEqual(pasteboard.string(forType: .string), "HELLO")
        XCTAssertEqual(postedEventCount, 1, "model paste transform must post exactly one paste keystroke")
    }

    @MainActor
    func testModelPasteFocusedTransformedImageSurfacesErrorAndDoesNotCloseOrPost() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))
        model.reload()
        wait { model.historyItems.count >= 1 }

        model.focusSelection(at: 0)
        model.beginSession()

        var didClose = false
        model.pasteFocused(transform: .uppercase, completion: { didClose = true })

        wait { didClose || model.actionFeedback != nil || model.errorMessage != nil }

        XCTAssertFalse(didClose, "a rejected transform must not close the dock")
        XCTAssertNil(model.actionFeedback, "a rejected transform must not show success feedback")
        XCTAssertNotNil(model.errorMessage, "a rejected transform must surface an error message")
        XCTAssertEqual(postedEventCount, 0)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    @MainActor
    func testModelPasteFocusedTransformedStaleCompletionDoesNotCloseReopenedDock() throws {
        // Session-generation guard must hold for transformed paste: a stale
        // completion from a previous dock session must not call the close
        // handler or mutate a newly reopened dock.
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("hello"))
        model.reload()
        wait { model.historyItems.count >= 1 }

        model.focusSelection(at: 0)
        model.beginSession()

        var didClose = false
        model.pasteFocused(transform: .uppercase, completion: { didClose = true })

        // End the session (hide) and start a new one (reopen) before the work
        // queue drains. The stale completion must be suppressed.
        model.endSession()
        model.beginSession()

        wait { postedEventCount > 0 || model.actionFeedback != nil || model.errorMessage != nil || didClose }

        XCTAssertFalse(didClose, "stale transformed-paste completion must not close a reopened dock")
    }

    // MARK: - Helpers

    // Build a minimal valid RTF document whose plain text is the given string.
    // Uses escaped plain-text characters so NSAttributedString can decode it.
    private func minimalRTF(carrying text: String) -> Data {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
        let rtf = "{\\rtf1\\ansi\\ansicpg1252\\fromansicpg1252 " + escaped + "}"
        return Data(rtf.utf8)
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
