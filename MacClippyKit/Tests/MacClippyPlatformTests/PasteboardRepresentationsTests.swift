import AppKit
import Foundation
import XCTest

import MacClippyCore
import MacClippyPlatform

final class PasteboardRepresentationsTests: XCTestCase {
    func testRepresentationsRetainsEveryUTIIncludingConcealedAndTransient() throws {
        let change = PasteboardChange(
            changeCount: 1,
            items: [PasteboardItem(types: [
                "public.utf8-plain-text",
                "public.html",
                "public.rtf",
                "public.tiff",
                "org.nspasteboard.ConcealedType",
                "org.nspasteboard.TransientType",
                "com.example.custom-uti",
                "dyn.age50u2u"
            ], representations: [
                "public.utf8-plain-text": Data("hello".utf8),
                "public.html": Data("<b>hi</b>".utf8),
                "public.rtf": Data("{\\rtf1 rich}".utf8),
                "public.tiff": Data([0x49, 0x49, 0x2A, 0x00]),
                "org.nspasteboard.ConcealedType": Data("concealed".utf8),
                "org.nspasteboard.TransientType": Data("transient".utf8),
                "com.example.custom-uti": Data("custom".utf8),
                "dyn.age50u2u": Data("dynamic".utf8)
            ])]
        )

        let representations = MacClippyCaptureMapper.representations(for: change)

        XCTAssertEqual(Set(representations.map(\.uti)), Set([
            "public.utf8-plain-text",
            "public.html",
            "public.rtf",
            "public.tiff",
            "org.nspasteboard.ConcealedType",
            "org.nspasteboard.TransientType",
            "com.example.custom-uti",
            "dyn.age50u2u"
        ]))
        for representation in representations {
            XCTAssertNotNil(representation.payloadBytes, "UTI \(representation.uti) should retain its payload")
            XCTAssertFalse(representation.payloadBytes?.isEmpty ?? true)
            XCTAssertEqual(representation.payloadState, .present, "advertised-with-payload UTIs should be .present")
        }
    }

    func testRepresentationsPreservesItemOrderAndDedupesAcrossItems() throws {
        let change = PasteboardChange(
            changeCount: 2,
            items: [
                PasteboardItem(types: ["public.utf8-plain-text", "public.html"], representations: [
                    "public.utf8-plain-text": Data("first".utf8),
                    "public.html": Data("<b>first</b>".utf8)
                ]),
                PasteboardItem(types: ["public.utf8-plain-text", "com.second"], representations: [
                    "public.utf8-plain-text": Data("second".utf8),
                    "com.second": Data("second-custom".utf8)
                ])
            ]
        )

        let representations = MacClippyCaptureMapper.representations(for: change)

        // The first occurrence of a UTI wins; subsequent duplicates are
        // dropped so the side table stays one row per UTI.
        XCTAssertEqual(representations.map(\.uti), ["public.utf8-plain-text", "public.html", "com.second"])
        XCTAssertEqual(representations[0].payloadBytes, Data("first".utf8))
    }

    func testRepresentationsRetainsEmptyAndUnavailablePayloadsAsMarkers() throws {
        // No-filter capture: every advertised UTI is retained. An empty
        // payload is kept as .present with empty Data; a provider-unavailable
        // payload (advertised in types but absent from representations) is
        // kept as .unavailable so the advertised type set is complete.
        let change = PasteboardChange(
            changeCount: 3,
            items: [PasteboardItem(types: [
                "public.utf8-plain-text",
                "public.html",
                "com.empty",
                "com.missing"
            ], representations: [
                "public.utf8-plain-text": Data("kept".utf8),
                "public.html": Data(),
                "com.empty": Data(),
                // com.missing intentionally absent: advertised but unavailable
            ])]
        )

        let representations = MacClippyCaptureMapper.representations(for: change)

        XCTAssertEqual(Set(representations.map(\.uti)), Set([
            "public.utf8-plain-text",
            "public.html",
            "com.empty",
            "com.missing"
        ]))
        let byUTI = Dictionary(uniqueKeysWithValues: representations.map { ($0.uti, $0) })
        XCTAssertEqual(byUTI["public.utf8-plain-text"]?.payloadBytes, Data("kept".utf8))
        XCTAssertEqual(byUTI["public.utf8-plain-text"]?.payloadState, .present)
        XCTAssertEqual(byUTI["public.html"]?.payloadBytes, Data())
        XCTAssertEqual(byUTI["public.html"]?.payloadState, .present)
        XCTAssertEqual(byUTI["com.empty"]?.payloadBytes, Data())
        XCTAssertEqual(byUTI["com.empty"]?.payloadState, .present)
        XCTAssertNil(byUTI["com.missing"]?.payloadBytes)
        XCTAssertNil(byUTI["com.missing"]?.blobID)
        XCTAssertEqual(byUTI["com.missing"]?.payloadState, .unavailable)
    }

    func testRepresentationsDoesNotCrashOnMalformedData() throws {
        // A representation whose payload is non-UTF8 bytes should still be
        // retained as raw Data; the mapper never decodes strings, so
        // malformed bytes cannot crash capture.
        let change = PasteboardChange(
            changeCount: 4,
            items: [PasteboardItem(types: [
                "public.utf8-plain-text",
                "com.binary.garbage"
            ], representations: [
                "public.utf8-plain-text": Data([0xFF, 0xFE, 0xFD, 0x00]),
                "com.binary.garbage": Data([0x00, 0x01, 0x02, 0x03])
            ])]
        )

        let representations = MacClippyCaptureMapper.representations(for: change)
        XCTAssertEqual(Set(representations.map(\.uti)), Set(["public.utf8-plain-text", "com.binary.garbage"]))
        XCTAssertEqual(representations.first { $0.uti == "com.binary.garbage" }?.payloadBytes, Data([0x00, 0x01, 0x02, 0x03]))
    }

    func testSlotLabelsKnownAndUnknownUTIs() {
        XCTAssertEqual(MacClippyCaptureMapper.slot(forUTI: "public.utf8-plain-text"), .text)
        XCTAssertEqual(MacClippyCaptureMapper.slot(forUTI: "public.rtf"), .rtf)
        XCTAssertEqual(MacClippyCaptureMapper.slot(forUTI: "public.html"), .html)
        XCTAssertEqual(MacClippyCaptureMapper.slot(forUTI: "public.tiff"), .image)
        XCTAssertEqual(MacClippyCaptureMapper.slot(forUTI: "public.file-url"), .files)
        XCTAssertEqual(MacClippyCaptureMapper.slot(forUTI: "com.unknown.nothing"), .other)
    }

    func testPlainTextFallbackDerivesPreviewFromRepresentations() {
        let representations = [
            MacClippyClipboardRepresentation(uti: "com.unknown", payloadBytes: Data([0xFF, 0xFE])),
            MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("fallback text".utf8))
        ]
        XCTAssertEqual(MacClippyCaptureMapper.plainText(for: representations), "fallback text")

        let htmlOnly = [
            MacClippyClipboardRepresentation(uti: "public.html", payloadBytes: Data("<p>hi <strong>there</strong></p>".utf8))
        ]
        XCTAssertEqual(MacClippyCaptureMapper.plainText(for: htmlOnly), "hi there")

        let binaryOnly = [
            MacClippyClipboardRepresentation(uti: "com.binary", payloadBytes: Data([0x00, 0x01]))
        ]
        XCTAssertNil(MacClippyCaptureMapper.plainText(for: binaryOnly))
    }
}
