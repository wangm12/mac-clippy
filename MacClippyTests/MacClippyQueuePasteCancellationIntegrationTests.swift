import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyQueueCancelIntegrationTests: XCTestCase {
    private var tempRoot: URL!
    private var pasteboard: NSPasteboard!
    private var runtime: MacClippyRuntime!
    private var control: MacClippyPasteTestControl!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyQueuePasteCancellation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyQueuePasteCancellation-\(UUID().uuidString)"))
        pasteboard.setString("previous clipboard", forType: .string)
        let control = MacClippyPasteTestControl()
        self.control = control

        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { [control] in control.isTrusted },
            postEvents: { [control] _, _ in control.recordPostedEventPair() },
            postEventsToProcess: { [control] _, _, _ in control.recordPostedEventPair() },
            preparer: { content, stagingPasteboard in
                let didPrepare = MacClippyPasteboardPreparer.prepare(content, on: stagingPasteboard)
                // Cancellation lands after staging but before validation and
                // the selected payload is committed to the named pasteboard.
                control.cancel()
                return didPrepare
            }
        )
        runtime = try MacClippyRuntime(
            paths: MacClippyPaths(rootURL: tempRoot),
            pasteInjector: injector
        )
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        pasteboard = nil
        control = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testCancellationDuringCurrentAttemptKeepsCurrentAndTailInRemainingIDs() throws {
        let current = try runtime.appendTestRecord(.text("current item"))
        let next = try runtime.appendTestRecord(.text("next item"))

        let result = try runtime.pasteQueued(
            ids: [current.id, next.id],
            shouldCancel: { [control] in control.isCancelled }
        )

        guard case let .cancelled(injectedIDs, unavailableIDs, unavailableKinds, remainingIDs) = result else {
            XCTFail("expected cancellation before the current payload is committed, got \(result)")
            return
        }
        XCTAssertTrue(injectedIDs.isEmpty)
        XCTAssertTrue(unavailableIDs.isEmpty)
        XCTAssertTrue(unavailableKinds.isEmpty)
        XCTAssertEqual(
            remainingIDs,
            [current.id, next.id],
            "the current item remains queued when cancellation prevents its injection"
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "previous clipboard")
        XCTAssertEqual(control.postedEventPairCount, 0)

        let history = try runtime.history(limit: 10, query: "")
        let frequencyByID = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0.meta.frequency) })
        XCTAssertEqual(frequencyByID[current.id], 0)
        XCTAssertEqual(frequencyByID[next.id], 0)
    }
}
