import AppKit
import Foundation
import MacClippyPlatform
import XCTest

final class PasteInjectorGenerationTests: XCTestCase {
    func testCommitValidationNewCopyPreventsSnippetDeleteAndPaste() {
        let pasteboard = makePasteboard("ContextNewCopy")
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let gate = MacClippyPasteInjectionGate()
        var beforePasteCount = 0
        var globalPostCount = 0
        var targetedPostIDs: [Int32] = []
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in globalPostCount += 1 },
            postEventsToProcess: { _, _, processID in targetedPostIDs.append(processID) }
        )

        let result = injector.inject(
            text: "snippet expansion",
            beforePaste: { beforePasteCount += 1; return true },
            validateCommitContext: {
                self.publish("new user copy", on: pasteboard)
                return true
            },
            gate: gate,
            targetProcessIdentifier: 42_123
        )

        XCTAssertEqual(result, .failed(.clipboardChanged))
        XCTAssertEqual(beforePasteCount, 0)
        XCTAssertEqual(globalPostCount, 0)
        XCTAssertTrue(targetedPostIDs.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    func testCancelAfterWritePreservesNewCopyAndSkipsSnippetCommit() {
        let pasteboard = makePasteboard("CancelNewCopy")
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let gate = MacClippyPasteInjectionGate()
        var beforePasteCount = 0
        var globalPostCount = 0
        var targetedPostCount = 0
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in globalPostCount += 1 },
            postEventsToProcess: { _, _, _ in targetedPostCount += 1 }
        )

        let result = injector.inject(
            text: "snippet expansion",
            beforePaste: { beforePasteCount += 1; return true },
            validateCommitContext: {
                gate.close()
                self.publish("copy concurrent with cancellation", on: pasteboard)
                return true
            },
            gate: gate,
            targetProcessIdentifier: 42_124
        )

        XCTAssertEqual(result, .failed(.clipboardChanged))
        XCTAssertEqual(beforePasteCount, 0)
        XCTAssertEqual(globalPostCount, 0)
        XCTAssertEqual(targetedPostCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "copy concurrent with cancellation")
    }

    func testManualFallbackDoesNotClaimSupersededPreparedClipboard() {
        let pasteboard = makePasteboard("ManualNewCopy")
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var trustChecks = 0
        var beforePasteCount = 0
        var globalPostCount = 0
        var targetedPostCount = 0
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: {
                trustChecks += 1
                if trustChecks == 2 {
                    self.publish("new user copy", on: pasteboard)
                    return false
                }
                return true
            },
            postEvents: { _, _ in globalPostCount += 1 },
            postEventsToProcess: { _, _, _ in targetedPostCount += 1 }
        )

        let result = injector.inject(
            text: "selected history item",
            beforePaste: { beforePasteCount += 1; return true },
            targetProcessIdentifier: 42_125
        )

        XCTAssertEqual(result, .failed(.clipboardChanged))
        XCTAssertEqual(beforePasteCount, 0)
        XCTAssertEqual(globalPostCount, 0)
        XCTAssertEqual(targetedPostCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
    }

    private func makePasteboard(_ label: String) -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("MacClippyPasteboardGeneration-\(label)-\(UUID().uuidString)"))
    }

    private func publish(_ text: String, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(text, forType: .string))
    }
}
