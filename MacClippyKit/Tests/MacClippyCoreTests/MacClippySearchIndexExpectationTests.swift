import XCTest

import MacClippyCore

final class MacClippySearchIndexExpectationTests: XCTestCase {
    func testImageWithoutOCROrLabelDoesNotRequireAnIndexRow() {
        let meta = meta(
            contentKind: .image,
            preview: "(image 4x4)",
            sourceAppBundleID: "com.apple.Safari"
        )
        XCTAssertFalse(MacClippySearchIndexExpectation.requiresIndex(meta))
    }

    func testImageWithOCRRequiresAnIndexRow() {
        let meta = meta(contentKind: .image, preview: "(image 4x4)", ocrText: "uniqueocr")
        XCTAssertTrue(MacClippySearchIndexExpectation.requiresIndex(meta))
    }

    func testTextPreviewRequiresAnIndexRow() {
        let meta = meta(contentKind: .text, preview: "hello from the clipboard")
        XCTAssertTrue(MacClippySearchIndexExpectation.requiresIndex(meta))
    }

    func testPlaceholderPreviewsDoNotRequireAnIndexRow() {
        XCTAssertFalse(
            MacClippySearchIndexExpectation.requiresIndex(
                meta(contentKind: .rtf, preview: "(rich text)")
            )
        )
        XCTAssertFalse(
            MacClippySearchIndexExpectation.requiresIndex(
                meta(contentKind: .text, preview: "(no preview)")
            )
        )
    }

    func testLabelAloneRequiresAnIndexRow() {
        let meta = meta(contentKind: .image, preview: "(image 8x8)", customLabel: "receipt")
        XCTAssertTrue(MacClippySearchIndexExpectation.requiresIndex(meta))
    }

    private func meta(
        contentKind: MacClippyContentKind,
        preview: String,
        sourceAppBundleID: String? = nil,
        customLabel: String? = nil,
        ocrText: String? = nil
    ) -> ClipboardItemMeta {
        ClipboardItemMeta(
            id: RecordID.generate(),
            created: Date(timeIntervalSince1970: 1),
            modified: Date(timeIntervalSince1970: 1),
            deviceID: DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            lamport: 1,
            contentKind: contentKind,
            preview: preview,
            sourceAppBundleID: sourceAppBundleID,
            customLabel: customLabel,
            ocrText: ocrText
        )
    }
}
