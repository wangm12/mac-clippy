import AppKit
import XCTest

import MacClippyPlatform

final class MacClippyPasteInjectorTests: XCTestCase {
    func testPrepareTextWritesPlainTextToInjectedPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPasteInjectorTests-\(UUID().uuidString)"))
        let injector = MacClippyPasteInjector(pasteboard: pasteboard, isProcessTrusted: { false })

        XCTAssertTrue(injector.prepareText("plain text"))
        XCTAssertEqual(pasteboard.string(forType: .string), "plain text")
    }

    func testPrepareImageWritesImageDataToNamedPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyImagePasteboard-\(UUID().uuidString)"))
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])

        XCTAssertTrue(MacClippyPasteboardPreparer.prepare(.image(data), on: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .png), data)
    }

    func testPrepareFilesWritesURLsToNamedPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyFilesPasteboard-\(UUID().uuidString)"))
        let urls = [URL(fileURLWithPath: "/tmp/one.txt"), URL(fileURLWithPath: "/tmp/two.txt")]

        XCTAssertTrue(MacClippyPasteboardPreparer.prepare(.files(urls), on: pasteboard))
        let pastedURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertEqual(pastedURLs, urls)
    }

    func testManualPasteRequiredRestoresOriginalPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPasteRestore-\(UUID().uuidString)"))
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let sentinel = MacClippyPasteboardWriteSentinel()
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { false },
            writeSentinel: sentinel
        )

        XCTAssertEqual(injector.inject(text: "replacement"), .manualPasteRequired)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(sentinel.pendingCount, 1, "the restored clipboard generation should be suppressed")
    }

    func testUnavailableOriginalProviderIsNotClearedWhenAutomaticPasteCannotProceed() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyUnavailableProvider-\(UUID().uuidString)"))
        let provider = UnavailablePasteboardItemProvider()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.string]))
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let changeCountBefore = pasteboard.changeCount
        let injector = MacClippyPasteInjector(pasteboard: pasteboard, isProcessTrusted: { true })

        XCTAssertEqual(injector.inject(text: "replacement"), .manualPasteRequired)
        XCTAssertEqual(pasteboard.changeCount, changeCountBefore)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.types, [.string])
    }

    func testBeforePasteIsNotCalledWhenAutomaticPastePreflightFails() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPasteBeforePasteFailure-\(UUID().uuidString)"))
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { false }
        )
        var didRun = false

        XCTAssertEqual(
            injector.inject(text: "replacement", beforePaste: { didRun = true }),
            .manualPasteRequired
        )
        XCTAssertFalse(didRun)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testBeforePasteRunsBeforeSuccessfulPasteEvents() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPasteBeforePasteSuccess-\(UUID().uuidString)"))
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var order: [String] = []
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in order.append("paste") }
        )

        XCTAssertEqual(
            injector.inject(text: "replacement", beforePaste: { order.append("beforePaste") }),
            .injected
        )
        XCTAssertEqual(order, ["beforePaste", "paste"])
    }
}

private final class UnavailablePasteboardItemProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        // Deliberately leave the promised data unavailable. The injector must
        // refuse to replace this clipboard rather than attempting a lossy
        // restore.
    }
}
