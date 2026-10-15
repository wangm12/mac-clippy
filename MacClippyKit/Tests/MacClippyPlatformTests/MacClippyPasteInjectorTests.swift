import AppKit
import MacClippyPlatform
import XCTest

final class MacClippyPasteInjectorTests: XCTestCase {
    func testPrepareTextWritesPlainTextToInjectedPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPasteInjectorTests-\(UUID().uuidString)"))
        let injector = MacClippyPasteInjector(pasteboard: pasteboard, isProcessTrusted: { false })

        XCTAssertNoThrow(try injector.prepareText("plain text"))
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

    func testPrepareItemsPreservesNativeItemAndTypeOrder() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyItemsPasteboard-\(UUID().uuidString)"))
        let items = [
            PasteboardItem(types: ["com.example.first", "public.utf8-plain-text"], representations: [
                "com.example.first": Data("custom 1".utf8),
                "public.utf8-plain-text": Data("first".utf8)
            ]),
            PasteboardItem(types: ["public.utf8-plain-text", "com.example.second"], representations: [
                "public.utf8-plain-text": Data("second".utf8),
                "com.example.second": Data("custom 2".utf8)
            ])
        ]

        XCTAssertTrue(MacClippyPasteboardPreparer.prepare(.items(items), on: pasteboard))

        let written = pasteboard.pasteboardItems ?? []
        XCTAssertEqual(written.count, 2)
        XCTAssertEqual(written[0].types.map(\.rawValue), ["com.example.first", "public.utf8-plain-text"])
        XCTAssertEqual(written[1].types.map(\.rawValue), ["public.utf8-plain-text", "com.example.second"])
        XCTAssertEqual(
            written[0].data(forType: NSPasteboard.PasteboardType("com.example.first")),
            Data("custom 1".utf8)
        )
        XCTAssertEqual(written[1].data(forType: .string), Data("second".utf8))
    }

    func testFailedPrepareRestoresOriginalPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPrepareRestore-\(UUID().uuidString)"))
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            preparer: { _, pasteboard in
                pasteboard.clearContents()
                return false
            }
        )

        XCTAssertThrowsError(try injector.prepareText("replacement")) { error in
            XCTAssertEqual(error as? MacClippyPasteboardPrepareError, .writeFailed)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testFailedPrepareDoesNotClobberForeignPasteboardWrite() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPrepareForeignWrite-\(UUID().uuidString)"))
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            writeObjects: { pasteboard, _ in
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("foreign", forType: .string))
                return false
            }
        )

        XCTAssertThrowsError(try injector.prepareText("replacement")) { error in
            XCTAssertTrue(
                error is MacClippyPasteboardPrepareError,
                "Expected a pasteboard prepare error, got \(error)"
            )
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "foreign")
    }

    func testFailedPrepareDoesNotClearIncompleteOriginalProvider() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPrepareUnavailable-\(UUID().uuidString)"))
        let provider = UnavailablePasteboardItemProvider()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.string]))
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let changeCountBefore = pasteboard.changeCount
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            preparer: { _, _ in
                XCTFail("the preparer must not run for an incomplete snapshot")
                return false
            }
        )

        XCTAssertThrowsError(try injector.prepareText("replacement")) { error in
            XCTAssertEqual(error as? MacClippyPasteboardPrepareError, .incompleteSnapshot)
        }
        XCTAssertEqual(pasteboard.changeCount, changeCountBefore)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.types, [.string])
    }

    func testManualFallbackLeavesSelectedContentReadyOnPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPasteRestore-\(UUID().uuidString)"))
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let sentinel = MacClippyPasteboardWriteSentinel()
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { false },
            writeSentinel: sentinel
        )

        XCTAssertEqual(injector.inject(text: "replacement"), .preparedForManualPaste)
        XCTAssertEqual(pasteboard.string(forType: .string), "replacement")
        XCTAssertEqual(sentinel.pendingCount, 1, "the prepared clipboard generation should be suppressed")
    }

    func testUnavailableOriginalProviderIsNotClearedWhenAutomaticPasteCannotProceed() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyUnavailableProvider-\(UUID().uuidString)"))
        let provider = UnavailablePasteboardItemProvider()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.string]))
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let changeCountBefore = pasteboard.changeCount
        let injector = MacClippyPasteInjector(pasteboard: pasteboard, isProcessTrusted: { true })

        XCTAssertEqual(injector.inject(text: "replacement"), .failed(.incompleteClipboard))
        XCTAssertEqual(pasteboard.changeCount, changeCountBefore)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.types, [.string])
    }

    func testManualFallbackDoesNotCallBeforePasteWhenAutomaticPreflightFails() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPasteBeforePasteFailure-\(UUID().uuidString)"))
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { false }
        )
        var didRun = false

        XCTAssertEqual(
            injector.inject(text: "replacement", beforePaste: { didRun = true; return true }),
            .preparedForManualPaste
        )
        XCTAssertFalse(didRun)
        XCTAssertEqual(pasteboard.string(forType: .string), "replacement")
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
            injector.inject(text: "replacement", beforePaste: { order.append("beforePaste"); return true }),
            .injected
        )
        XCTAssertEqual(order, ["beforePaste", "paste"])
    }

    func testClosedSideEffectGatePreventsPasteboardWritesAndEvents() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPasteGate-\(UUID().uuidString)"))
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var eventCount = 0
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in eventCount += 1 }
        )
        let gate = MacClippyPasteInjectionGate()
        gate.close()

        XCTAssertThrowsError(try injector.prepareText("replacement", gate: gate)) { error in
            XCTAssertEqual(error as? MacClippyPasteboardPrepareError, .gateClosed)
        }
        XCTAssertEqual(injector.inject(text: "replacement", gate: gate), .cancelled)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(eventCount, 0)
    }

    func testFailedPrepareRestoresOriginalImageRepresentation() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPrepareRestoreImage-\(UUID().uuidString)"))
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        XCTAssertTrue(pasteboard.setData(image, forType: .png))
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            preparer: { _, pasteboard in
                pasteboard.clearContents()
                return false
            }
        )

        XCTAssertThrowsError(try injector.prepare(.image(Data([0x00])))) { error in
            XCTAssertEqual(error as? MacClippyPasteboardPrepareError, .writeFailed)
        }
        XCTAssertEqual(pasteboard.data(forType: .png), image)
    }

    func testFailedPrepareRestoresURLAndTextRepresentations() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPrepareRestoreMulti-\(UUID().uuidString)"))
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("https://example.com", forType: .URL))
        XCTAssertTrue(item.setString("example link", forType: .string))
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            preparer: { _, pasteboard in
                pasteboard.clearContents()
                return false
            }
        )

        XCTAssertThrowsError(try injector.prepareText("replacement")) { error in
            XCTAssertEqual(error as? MacClippyPasteboardPrepareError, .writeFailed)
        }
        XCTAssertEqual(pasteboard.string(forType: .URL), "https://example.com")
        XCTAssertEqual(pasteboard.string(forType: .string), "example link")
    }

    func testClosedGateThrowsGateClosed() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPrepareGateThrow-\(UUID().uuidString)"))
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let injector = MacClippyPasteInjector(pasteboard: pasteboard)
        let gate = MacClippyPasteInjectionGate()
        gate.close()

        XCTAssertThrowsError(try injector.prepareText("replacement", gate: gate)) { error in
            XCTAssertEqual(error as? MacClippyPasteboardPrepareError, .gateClosed)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }
}

private final class UnavailablePasteboardItemProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(
        _: NSPasteboard?,
        item _: NSPasteboardItem,
        provideDataForType _: NSPasteboard.PasteboardType
    ) {
        // Deliberately leave the promised data unavailable. The injector must
        // refuse to replace this clipboard rather than attempting a lossy
        // restore.
    }
}
