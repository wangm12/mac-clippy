import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntimeBatchOperationsTests {
    func testCapturedMultiItemFormatsSurviveReopenSearchAndNormalPlainReplay() throws {
        let text = "CJK clipboard 🚀 phasefiveitem"
        let capturedID = try captureMultiItemRecord(text)
        let storedRepresentations = try runtime.clipboardStore.playbackSnapshot(for: capturedID).representations
        XCTAssertEqual(
            storedRepresentations.filter { $0.uti != "public.utf16-external-plain-text" },
            expectedMultiItemRepresentations(text)
        )

        try reopenRuntimeForRepresentationReplay()
        XCTAssertEqual(try runtime.history(limit: 10, query: "phasefiveitem").map(\.id), [capturedID])
        try assertMultiItemReplay(capturedID, text: text)
    }

    private func captureMultiItemRecord(_ text: String) throws -> RecordID {
        runtime.start()
        runtime.observer.poll()

        let firstItem = NSPasteboardItem()
        firstItem.setData(Data("custom first".utf8), forType: NSPasteboard.PasteboardType("com.example.custom"))
        let secondItem = NSPasteboardItem()
        secondItem.setData(Data(text.utf8), forType: .string)
        secondItem.setData(Data("<i>second format</i>".utf8), forType: .html)
        secondItem.setData(
            Data("custom second".utf8),
            forType: NSPasteboard.PasteboardType("com.example.custom")
        )
        secondItem.setData(Data("{\\rtf1 second format}".utf8), forType: .rtf)
        let beforeWrite = pasteboardEnvironment.pasteboard.changeCount
        pasteboardEnvironment.pasteboard.clearContents()
        XCTAssertTrue(pasteboardEnvironment.pasteboard.writeObjects([firstItem, secondItem]))
        XCTAssertGreaterThan(pasteboardEnvironment.pasteboard.changeCount, beforeWrite)
        let sourceBundleID = "com.example.macclippy-tests-source"
        let materialized = MacClippySystemPasteboardReader(
            pasteboard: pasteboardEnvironment.pasteboard,
            sourceAppBundleID: { sourceBundleID }
        ).read()
        XCTAssertEqual(materialized.sourceAppBundleID, sourceBundleID)
        XCTAssertEqual(materialized.changeCount, pasteboardEnvironment.pasteboard.changeCount)
        XCTAssertEqual(materialized.items.count, 2)
        XCTAssertEqual(MacClippyCaptureMapper.projection(for: materialized).payload, .text(text))
        runtime.observer.poll()
        runtime.drainCaptureQueueForTest()

        let captured = try runtime.history(limit: 10, query: "")
        XCTAssertEqual(captured.count, 1)
        let capturedID = try XCTUnwrap(captured.first?.id)
        XCTAssertEqual(try runtime.history(limit: 10, query: "phasefiveitem").map(\.id), [capturedID])
        return capturedID
    }

    private func expectedMultiItemRepresentations(_ text: String) -> [MacClippyClipboardRepresentation] {
        [
            MacClippyClipboardRepresentation(
                itemIndex: 0,
                uti: "com.example.custom",
                payloadBytes: Data("custom first".utf8)
            ),
            MacClippyClipboardRepresentation(
                itemIndex: 1,
                uti: NSPasteboard.PasteboardType.string.rawValue,
                payloadBytes: Data(text.utf8)
            ),
            MacClippyClipboardRepresentation(
                itemIndex: 1,
                uti: NSPasteboard.PasteboardType.html.rawValue,
                payloadBytes: Data("<i>second format</i>".utf8)
            ),
            MacClippyClipboardRepresentation(
                itemIndex: 1,
                uti: "com.example.custom",
                payloadBytes: Data("custom second".utf8)
            ),
            MacClippyClipboardRepresentation(
                itemIndex: 1,
                uti: NSPasteboard.PasteboardType.rtf.rawValue,
                payloadBytes: Data("{\\rtf1 second format}".utf8)
            )
        ]
    }

    private func reopenRuntimeForRepresentationReplay() throws {
        runtime.closeForTesting()
        pasteboardEnvironment = MacClippyAppTestPasteboardEnvironment(
            label: "RuntimeMultiItemReopen",
            sourceAppBundleID: { "com.example.macclippy-tests-source" }
        )
        runtime = try MacClippyRuntime(
            paths: MacClippyPaths(rootURL: tempRoot),
            keychain: MacClippyInMemoryKeychain.shared,
            observer: pasteboardEnvironment.observer,
            pasteInjector: pasteboardEnvironment.injector,
            enableSnippetExpansion: false,
            preferencesDefaults: pasteboardEnvironment.preferencesDefaults
        )
    }

    private func assertMultiItemReplay(_ capturedID: RecordID, text: String) throws {
        try runtime.copy(id: capturedID)
        let normalItems = pasteboardEnvironment.pasteboard.pasteboardItems ?? []
        XCTAssertEqual(normalItems.count, 2)
        XCTAssertEqual(observablePasteboardTypes(normalItems[0]), ["com.example.custom"])
        XCTAssertEqual(observablePasteboardTypes(normalItems[1]), [
            "public.utf8-plain-text", "public.html", "com.example.custom", "public.rtf"
        ])
        XCTAssertEqual(normalItems[1].data(forType: .string), Data(text.utf8))

        try runtime.copy(id: capturedID, plain: true)
        XCTAssertEqual(pasteboardEnvironment.pasteboard.string(forType: .string), text)
        XCTAssertEqual(pasteboardEnvironment.pasteboard.pasteboardItems?.count, 1)
    }

    func testHistoryReplayPreservesNativeItemsAndHasAnExplicitPlainTextPath() throws {
        let text = "你好 👋"
        let meta = try runtime.appendTestRecord(
            .text(text),
            representations: [
                MacClippyClipboardRepresentation(
                    itemIndex: 0,
                    uti: "com.example.custom",
                    payloadBytes: Data("custom item".utf8)
                ),
                MacClippyClipboardRepresentation(
                    itemIndex: 0,
                    uti: "public.html",
                    payloadBytes: Data("<b>first item</b>".utf8)
                ),
                MacClippyClipboardRepresentation(
                    itemIndex: 1,
                    uti: "public.utf8-plain-text",
                    payloadBytes: Data(text.utf8)
                ),
                MacClippyClipboardRepresentation(
                    itemIndex: 1,
                    uti: "public.rtf",
                    payloadBytes: Data("{\\rtf1 second item}".utf8)
                )
            ]
        )

        XCTAssertEqual(try runtime.paste(id: meta.id), .injected)
        let normalItems = pasteboardEnvironment.pasteboard.pasteboardItems ?? []
        XCTAssertEqual(normalItems.count, 2)
        XCTAssertEqual(observablePasteboardTypes(normalItems[0]), ["com.example.custom", "public.html"])
        XCTAssertEqual(observablePasteboardTypes(normalItems[1]), ["public.utf8-plain-text", "public.rtf"])
        XCTAssertEqual(
            normalItems[0].data(forType: NSPasteboard.PasteboardType("com.example.custom")),
            Data("custom item".utf8)
        )
        XCTAssertEqual(normalItems[0].data(forType: .html), Data("<b>first item</b>".utf8))
        XCTAssertEqual(normalItems[1].data(forType: .string), Data(text.utf8))

        try runtime.copy(id: meta.id, plain: true)

        XCTAssertEqual(pasteboardEnvironment.pasteboard.string(forType: .string), text)
        XCTAssertEqual(pasteboardEnvironment.pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(
            pasteboardEnvironment.pasteboard.pasteboardItems?.first?.types,
            [.string]
        )
    }

    func testEditingLaterPrimaryTextPreservesOtherItemsAndInvalidatesStaleFormats() throws {
        let original = "before"
        let meta = try runtime.appendTestRecord(
            .text(original),
            representations: [
                MacClippyClipboardRepresentation(
                    itemIndex: 0,
                    uti: "com.example.custom",
                    payloadBytes: Data("keep".utf8)
                ),
                MacClippyClipboardRepresentation(
                    itemIndex: 0,
                    uti: "public.html",
                    payloadBytes: Data("<b>unrelated</b>".utf8)
                ),
                MacClippyClipboardRepresentation(
                    itemIndex: 1,
                    uti: "public.utf8-plain-text",
                    payloadBytes: Data(original.utf8)
                ),
                MacClippyClipboardRepresentation(
                    itemIndex: 1,
                    uti: "public.html",
                    payloadBytes: Data("<b>stale primary format</b>".utf8)
                )
            ]
        )

        _ = try runtime.edit(id: meta.id, text: "after")
        try runtime.copy(id: meta.id)

        let items = pasteboardEnvironment.pasteboard.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].data(forType: NSPasteboard.PasteboardType("com.example.custom")), Data("keep".utf8))
        XCTAssertEqual(items[0].data(forType: .html), Data("<b>unrelated</b>".utf8))
        XCTAssertEqual(observablePasteboardTypes(items[1]), ["public.utf8-plain-text"])
        XCTAssertEqual(items[1].data(forType: .string), Data("after".utf8))

        try runtime.copy(id: meta.id, plain: true)
        XCTAssertEqual(pasteboardEnvironment.pasteboard.string(forType: .string), "after")
    }

    func testImageCompressionKeepsPrimaryNativeItemAndNormalReplay() throws {
        let fixture = try appendLargeImageRecord()
        let meta = fixture.meta
        let imageBlobID = fixture.imageBlobID

        let report = try runtime.compressOldImages()
        let compressed = try runtime.clipboardStore.playbackSnapshot(for: meta.id)

        XCTAssertEqual(report.compressedCount, 1)
        XCTAssertGreaterThan(report.bytesSaved, 0)
        guard case let .image(compressedBlobID, width, height) = compressed.record else {
            return XCTFail("expected an image record after compression")
        }
        XCTAssertNotEqual(compressedBlobID, imageBlobID)
        XCTAssertLessThanOrEqual(max(width, height), MacClippyStorageDashboardPolicy.compressTargetMaxPixelSize)
        XCTAssertEqual(compressed.representations.map(\.itemIndex), [0, 1, 1])
        XCTAssertEqual(compressed.representations.map(\.uti), [
            "public.utf8-plain-text", "public.jpeg", "com.example.image-label"
        ])
        XCTAssertFalse(try runtime.blobStore.contains(id: imageBlobID))

        try runtime.copy(id: meta.id)

        let replayItems = pasteboardEnvironment.pasteboard.pasteboardItems ?? []
        XCTAssertEqual(replayItems.count, 2)
        XCTAssertEqual(replayItems[0].data(forType: .string), Data("image caption".utf8))
        XCTAssertEqual(
            replayItems[1].data(forType: NSPasteboard.PasteboardType("public.jpeg")),
            try runtime.blobStore.read(id: compressedBlobID)
        )
        XCTAssertEqual(
            replayItems[1].data(forType: NSPasteboard.PasteboardType("com.example.image-label")),
            Data("keep image label".utf8)
        )
    }

    private func appendLargeImageRecord() throws -> (meta: ClipboardItemMeta, imageBlobID: String) {
        let imageData = try noisyPNG(width: 2_050, height: 2_050)
        let imageBlobID = try runtime.blobStore.write(imageData)
        let meta = try runtime.appendTestRecord(
            .image(blobID: imageBlobID, width: 2_050, height: 2_050),
            representations: [
                MacClippyClipboardRepresentation(
                    itemIndex: 0,
                    uti: "public.utf8-plain-text",
                    payloadBytes: Data("image caption".utf8)
                ),
                MacClippyClipboardRepresentation(
                    itemIndex: 1,
                    uti: "public.png",
                    payloadBytes: nil,
                    blobID: imageBlobID,
                    payloadState: .spilled
                ),
                MacClippyClipboardRepresentation(
                    itemIndex: 1,
                    uti: "com.example.image-label",
                    payloadBytes: Data("keep image label".utf8)
                )
            ],
            now: Date().addingTimeInterval(-30 * 24 * 60 * 60)
        )
        return (meta, imageBlobID)
    }
}
