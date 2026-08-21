import AppKit
import Foundation
import XCTest

import MacClippyPlatform

final class MacClippyPasteboardWriteSentinelTests: XCTestCase {
    func testConsumeReturnsTrueExactlyOnceForRegisteredChangeCount() {
        let sentinel = MacClippyPasteboardWriteSentinel()
        sentinel.beginWrite(expectedChangeCount: 42)

        XCTAssertTrue(sentinel.consume(changeCount: 42), "first consume should match the registered token")
        XCTAssertFalse(sentinel.consume(changeCount: 42), "second consume should not match again")
        XCTAssertEqual(sentinel.pendingCount, 0)
    }

    func testConsumeReturnsFalseForUnregisteredChangeCount() {
        let sentinel = MacClippyPasteboardWriteSentinel()
        sentinel.beginWrite(expectedChangeCount: 100)

        XCTAssertFalse(sentinel.consume(changeCount: 99))
        XCTAssertFalse(sentinel.consume(changeCount: 101))
        XCTAssertEqual(sentinel.pendingCount, 1)
        XCTAssertTrue(sentinel.consume(changeCount: 100))
    }

    func testResetDropsAllPendingTokens() {
        let sentinel = MacClippyPasteboardWriteSentinel()
        sentinel.beginWrite(expectedChangeCount: 1)
        sentinel.beginWrite(expectedChangeCount: 2)
        XCTAssertEqual(sentinel.pendingCount, 2)

        sentinel.reset()

        XCTAssertEqual(sentinel.pendingCount, 0)
        XCTAssertFalse(sentinel.consume(changeCount: 1))
        XCTAssertFalse(sentinel.consume(changeCount: 2))
    }

    func testCoordinatorStampsPasteboardWriteAndRegistersToken() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippySentinelTests-\(UUID().uuidString)"))
        let sentinel = MacClippyPasteboardWriteSentinel()
        let before = pasteboard.changeCount

        let success = MacClippyPasteboardWriteCoordinator.write(
            .text("internal write"),
            on: pasteboard,
            sentinel: sentinel
        )

        XCTAssertTrue(success)
        let after = pasteboard.changeCount
        XCTAssertEqual(after, before + 1, "clearContents should bump changeCount by exactly one")
        XCTAssertTrue(sentinel.consume(changeCount: after), "the new changeCount should be registered as an internal write")
        XCTAssertEqual(pasteboard.string(forType: .string), "internal write")
    }

    func testInjectorWithSentinelSuppressesRecaptureViaObserver() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippySentinelObserverTests-\(UUID().uuidString)"))
        let sentinel = MacClippyPasteboardWriteSentinel()
        let reader = SystemPasteboardReader(
            pasteboard: pasteboard,
            sourceAppBundleID: { "com.macallyouneed.macclippy" }
        )
        let observer = PasteboardObserver(reader: reader, writeSentinel: sentinel, pollInterval: 1)
        var capturedChanges: [PasteboardChange] = []
        observer.start { capturedChanges.append($0) }
        observer.poll()

        let injector = MacClippyPasteInjector(pasteboard: pasteboard, isProcessTrusted: { false }, writeSentinel: sentinel)

        // External write: a non-Mac-Clippy actor writes to the pasteboard.
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("external", forType: .string))
        observer.poll()
        XCTAssertEqual(capturedChanges.count, 1, "external write should be captured")

        // Internal write: the injector writes through the sentinel; the
        // observer should skip this changeCount.
        XCTAssertNoThrow(try injector.prepareText("internal"))
        observer.poll()
        XCTAssertEqual(capturedChanges.count, 1, "internal write should be suppressed by the sentinel")

        // Another external write should be captured again.
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("external again", forType: .string))
        observer.poll()
        XCTAssertEqual(capturedChanges.count, 2)

        observer.stop()
    }

    func testInjectorWithoutSentinelDoesNotSuppressRecapture() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyNoSentinelTests-\(UUID().uuidString)"))
        let reader = SystemPasteboardReader(
            pasteboard: pasteboard,
            sourceAppBundleID: { "com.macallyouneed.macclippy" }
        )
        let observer = PasteboardObserver(reader: reader, pollInterval: 1)
        var capturedChanges: [PasteboardChange] = []
        observer.start { capturedChanges.append($0) }
        observer.poll()

        let injector = MacClippyPasteInjector(pasteboard: pasteboard, isProcessTrusted: { false })

        XCTAssertNoThrow(try injector.prepareText("no sentinel"))
        observer.poll()
        XCTAssertEqual(capturedChanges.count, 1, "without a sentinel the injector write is recaptured")

        observer.stop()
    }

    func testHistoryCopyWithSentinelIsRecapturedByObserver() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyHistoryCopyTests-\(UUID().uuidString)"))
        let sentinel = MacClippyPasteboardWriteSentinel()
        let reader = SystemPasteboardReader(
            pasteboard: pasteboard,
            sourceAppBundleID: { "com.macallyouneed.macclippy" }
        )
        let observer = PasteboardObserver(reader: reader, writeSentinel: sentinel, pollInterval: 1)
        var capturedChanges: [PasteboardChange] = []
        observer.start { capturedChanges.append($0) }
        observer.poll()

        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { false },
            writeSentinel: sentinel
        )

        XCTAssertNoThrow(try injector.prepareTextForHistory("OCR text"))
        XCTAssertEqual(sentinel.pendingCount, 0, "history copies must not register an internal-write token")

        observer.poll()

        XCTAssertEqual(capturedChanges.count, 1)
        XCTAssertEqual(
            capturedChanges.first?.items.first?.string(forType: NSPasteboard.PasteboardType.string.rawValue),
            "OCR text"
        )
        observer.stop()
    }
}
