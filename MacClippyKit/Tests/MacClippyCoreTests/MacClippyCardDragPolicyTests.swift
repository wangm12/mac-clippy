import XCTest

@testable import MacClippyCore

final class MacClippyCardDragPolicyTests: XCTestCase {
    func testInternalRecordTypeIsNotPublicPlainText() {
        XCTAssertEqual(
            MacClippyCardDragPolicy.recordTypeIdentifier,
            "com.macallyouneed.macclippy.record-id"
        )
        XCTAssertNotEqual(
            MacClippyCardDragPolicy.recordTypeIdentifier,
            "public.utf8-plain-text"
        )
        XCTAssertEqual(
            MacClippyCardDragPolicy.typeIdentifier(for: .recordID),
            MacClippyCardDragPolicy.recordTypeIdentifier
        )
        XCTAssertEqual(
            MacClippyCardDragPolicy.typeIdentifier(for: .plainText),
            "public.utf8-plain-text"
        )
    }

    func testRepresentationsExportContentWithoutReplacingTheInternalRecordID() {
        XCTAssertEqual(
            MacClippyCardDragPolicy.representations(for: .text),
            [.recordID, .plainText]
        )
        XCTAssertEqual(
            MacClippyCardDragPolicy.representations(for: .rtf),
            [.recordID, .rtf, .plainText]
        )
        XCTAssertEqual(
            MacClippyCardDragPolicy.representations(for: .html),
            [.recordID, .html, .plainText]
        )
        XCTAssertEqual(
            MacClippyCardDragPolicy.representations(for: .image),
            [.recordID, .image]
        )
        XCTAssertEqual(
            MacClippyCardDragPolicy.representations(for: .files),
            [.recordID, .fileURL]
        )
    }

    func testPinboardDropReadsOnlyTheInternalRecordType() {
        XCTAssertEqual(
            MacClippyClipboardDropPolicy.preferredTypeIdentifier(
                among: ["public.utf8-plain-text", MacClippyCardDragPolicy.recordTypeIdentifier]
            ),
            MacClippyCardDragPolicy.recordTypeIdentifier
        )
        XCTAssertNil(
            MacClippyClipboardDropPolicy.preferredTypeIdentifier(
                among: ["public.utf8-plain-text", "public.text"]
            )
        )
    }
}
