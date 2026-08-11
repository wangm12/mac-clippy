import AppKit
import Foundation
import XCTest

import MacClippyCore
import MacClippyPlatform

final class PasteboardMappingTests: XCTestCase {
    func testCaptureProjectionReusesTheMappedPrimaryAndRepresentationSet() throws {
        let change = PasteboardChange(
            changeCount: 1,
            items: [PasteboardItem(
                types: [
                    NSPasteboard.PasteboardType.html.rawValue,
                    NSPasteboard.PasteboardType.string.rawValue
                ],
                representations: [
                    NSPasteboard.PasteboardType.html.rawValue: Data("<b>Hello</b>".utf8),
                    NSPasteboard.PasteboardType.string.rawValue: Data("Hello".utf8)
                ]
            )]
        )

        let projection = MacClippyCaptureMapper.projection(for: change)

        XCTAssertEqual(projection.payload, MacClippyCaptureMapper.payload(for: change))
        XCTAssertEqual(
            projection.representations,
            MacClippyCaptureMapper.representations(for: change)
        )
        XCTAssertEqual(projection.searchableText, "Hello")
    }

    func testImageWinsOverOtherRepresentations() throws {
        let imageData = Data([0, 1, 2])
        let change = PasteboardChange(
            changeCount: 1,
            items: [PasteboardItem(types: [
                NSPasteboard.PasteboardType.string.rawValue,
                NSPasteboard.PasteboardType.tiff.rawValue,
                NSPasteboard.PasteboardType.html.rawValue
            ], representations: [
                NSPasteboard.PasteboardType.string.rawValue: Data("plain text".utf8),
                NSPasteboard.PasteboardType.tiff.rawValue: imageData,
                NSPasteboard.PasteboardType.html.rawValue: Data("<b>html</b>".utf8)
            ])]
        )

        guard case let .image(data, _, _) = try XCTUnwrap(MacClippyCaptureMapper.payload(for: change)) else {
            return XCTFail("Expected image payload")
        }
        XCTAssertEqual(data, imageData)
    }

    func testTextBlocklistIsAppliedToMappedText() throws {
        let change = PasteboardChange(
            changeCount: 1,
            items: [PasteboardItem(
                types: [NSPasteboard.PasteboardType.string.rawValue],
                representations: [NSPasteboard.PasteboardType.string.rawValue: Data("password = secret".utf8)]
            )]
        )
        let payload = try XCTUnwrap(MacClippyCaptureMapper.payload(for: change))
        let blocklist = try RegexBlocklist(patterns: ["password\\s*="])

        XCTAssertTrue(MacClippyCaptureMapper.shouldExclude(payload, using: blocklist))
        XCTAssertFalse(MacClippyCaptureMapper.shouldExclude(payload, using: try RegexBlocklist()))
    }

    func testNonImageRepresentationsUseDeterministicPriority() throws {
        let rtf = Data("{\\rtf1 rich}".utf8)
        let html = Data("<b>html</b>".utf8)
        let fileURL = Data("file:///tmp/example.txt".utf8)

        let textChange = PasteboardChange(changeCount: 1, items: [PasteboardItem(
            types: ["public.file-url", "public.html", "public.rtf", "public.utf8-plain-text"],
            representations: [
                "public.file-url": fileURL,
                "public.html": html,
                "public.rtf": rtf,
                "public.utf8-plain-text": Data("text".utf8)
            ]
        )])
        guard case .text = try XCTUnwrap(MacClippyCaptureMapper.payload(for: textChange)) else {
            return XCTFail("Expected text payload")
        }

        let rtfChange = PasteboardChange(changeCount: 2, items: [PasteboardItem(
            types: ["public.file-url", "public.html", "public.rtf"],
            representations: ["public.file-url": fileURL, "public.html": html, "public.rtf": rtf]
        )])
        guard case .rtf = try XCTUnwrap(MacClippyCaptureMapper.payload(for: rtfChange)) else {
            return XCTFail("Expected RTF payload")
        }

        let htmlChange = PasteboardChange(changeCount: 3, items: [PasteboardItem(
            types: ["public.file-url", "public.html"],
            representations: ["public.file-url": fileURL, "public.html": html]
        )])
        guard case .html = try XCTUnwrap(MacClippyCaptureMapper.payload(for: htmlChange)) else {
            return XCTFail("Expected HTML payload")
        }

        let fileChange = PasteboardChange(
            changeCount: 4,
            items: [PasteboardItem(types: ["public.file-url"], representations: ["public.file-url": fileURL])]
        )
        guard case .files = try XCTUnwrap(MacClippyCaptureMapper.payload(for: fileChange)) else {
            return XCTFail("Expected file payload")
        }
    }

    func testClipboardTextConvertsHTMLAndRTFToPlainText() throws {
        XCTAssertEqual(
            MacClippyClipboardText.plainText(from: .html("<p>Hello <strong>world</strong></p>")),
            "Hello world"
        )

        let attributed = NSAttributedString(string: "Rich text")
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        XCTAssertEqual(MacClippyClipboardText.plainText(from: .rtf(rtf)), "Rich text")
        XCTAssertNil(MacClippyClipboardText.plainText(from: .image(blobID: "blob", width: 1, height: 1)))
    }
}
