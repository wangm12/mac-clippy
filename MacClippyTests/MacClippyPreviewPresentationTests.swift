import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippyPreviewPresentationTests: XCTestCase {
    private var tempRoot: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyPreviewPresentationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: tempRoot))
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testHTMLPreviewPayloadKeepsRichTextAndPlainText() throws {
        let meta = try runtime.appendTestRecord(.html("<b>Hi</b>"))

        let payload = try runtime.preview(id: meta.id)

        guard case let .richText(richText, plain, characterCount) = payload else {
            XCTFail("Expected HTML preview to use richText payload, got \(payload)")
            return
        }
        XCTAssertTrue(plain.contains("Hi"))
        XCTAssertTrue(richText.attributed.string.contains("Hi"))
        XCTAssertEqual(characterCount, plain.count)
    }

    func testTruncatedRTFPreviewPreservesAttributesOnKeptPrefix() throws {
        let boldPrefix = "BoldPrefix"
        let text = boldPrefix
            + String(repeating: "x", count: MacClippyDockPreviewTextPolicy.maxRenderedCharacters + 10)
        let source = NSMutableAttributedString(string: text)
        source.addAttribute(
            .font,
            value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
            range: NSRange(location: 0, length: boldPrefix.utf16.count)
        )
        let rtf = try source.data(
            from: NSRange(location: 0, length: source.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let meta = try runtime.appendTestRecord(.rtf(rtf))

        let payload = try runtime.preview(id: meta.id)

        guard case let .richText(richText, plain, characterCount) = payload else {
            XCTFail("Expected RTF preview to use richText payload, got \(payload)")
            return
        }
        XCTAssertTrue(plain.hasPrefix(boldPrefix))
        XCTAssertTrue(plain.contains("Preview shortened for performance"))
        XCTAssertEqual(characterCount, text.count)
        let font = try XCTUnwrap(
            richText.attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testRichTextPreviewBoxIsNotAffectedByLaterMutationOfItsSource() {
        let mutable = NSMutableAttributedString(string: "before")

        let boxed = MacClippyPreviewRichText(mutable)
        mutable.append(NSAttributedString(string: " after"))

        XCTAssertEqual(boxed.attributed.string, "before")
    }

    func testTextPreviewClassificationIsBoundedToTheRenderedPrefix() throws {
        // A payload larger than the rendered bound is never fully parsed or
        // pretty-printed: the preview would truncate that work away anyway.
        let oversizedJSON = "[" + Array(
            repeating: "\"aaaaaaaaaa\"",
            count: MacClippyDockPreviewTextPolicy.maxRenderedCharacters / 8
        ).joined(separator: ",") + "]"
        XCTAssertGreaterThan(oversizedJSON.count, MacClippyDockPreviewTextPolicy.maxRenderedCharacters)
        let meta = try runtime.appendTestRecord(.text(oversizedJSON))

        let payload = try runtime.preview(id: meta.id)

        guard case let .text(text) = payload else {
            XCTFail("Expected an oversized text payload to use the text preview, got \(payload)")
            return
        }
        XCTAssertNotEqual(text.kind, .json)
        XCTAssertEqual(text.characterCount, oversizedJSON.count)
        XCTAssertTrue(text.displayText.contains("Preview shortened for performance"))
    }

    func testJSONPreviewDisplayTextUsesPrettyJSON() throws {
        let raw = "{\"b\":1,\"a\":2}"
        let meta = try runtime.appendTestRecord(.text(raw))

        let payload = try runtime.preview(id: meta.id)

        guard case let .text(text) = payload else {
            XCTFail("Expected JSON preview to use text payload, got \(payload)")
            return
        }
        XCTAssertEqual(text.kind, .json)
        XCTAssertEqual(text.displayText, TextTransform.prettyJSON.apply(to: raw))
        XCTAssertTrue(text.displayText.contains("\n"))
        XCTAssertLessThan(
            text.displayText.range(of: "\"a\"")!.lowerBound,
            text.displayText.range(of: "\"b\"")!.lowerBound
        )
    }

    func testCodePreviewDoesNotUseHardcodedDarkPalette() throws {
        let source = try appSource(named: "MacClippyDockPreview.swift")

        XCTAssertFalse(source.contains("Color(red: 0.10, green: 0.11, blue: 0.14)"))
        XCTAssertFalse(source.contains("NSColor(calibratedRed: 0.85, green: 0.88, blue: 0.93, alpha: 1)"))
    }

    func testClipboardCardContentUsesCorePresentationKind() throws {
        let source = try appSource(named: "MacClippyClipboardCardLabel.swift")

        XCTAssertTrue(source.contains("MacClippyClipboardPresentation.kind(forPlainText:"))
        XCTAssertFalse(source.contains("MacClippyDockURLPolicy.url(from: classificationPreview)"))
        XCTAssertFalse(source.contains("MacClippyDockCodePolicy.isCode(classificationPreview)"))
    }

    private func appSource(named fileName: String) throws -> String {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacClippy")
        let fileURL = sourceRoot.appendingPathComponent(fileName)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
