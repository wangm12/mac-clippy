import XCTest

@testable import MacClippyCore
@testable import MacClippyPlatform

final class MacClippyCardDragExportPolicyTests: XCTestCase {
    func testPlainTextExportIsTheBodyNotTheRecordID() {
        let id = RecordID.generate()
        let payload = MacClippyCardDragExportPolicy.payload(
            for: .plainText,
            recordID: id,
            content: .text("hello from notes")
        )

        XCTAssertEqual(payload?.typeIdentifier, "public.utf8-plain-text")
        XCTAssertEqual(payload?.data, Data("hello from notes".utf8))
        XCTAssertNotEqual(payload?.data, Data(id.rawValue.utf8))
    }

    func testRecordIDStaysOnThePrivateType() {
        let id = RecordID.generate()
        let payload = MacClippyCardDragExportPolicy.payload(
            for: .recordID,
            recordID: id,
            content: .text("hello from notes")
        )

        XCTAssertEqual(payload?.typeIdentifier, MacClippyCardDragPolicy.recordTypeIdentifier)
        XCTAssertEqual(payload?.data, Data(id.rawValue.utf8))
    }

    func testImageExportUsesPNGOrTIFFFromTheStoredBytes() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let payload = MacClippyCardDragExportPolicy.payload(
            for: .image,
            recordID: .generate(),
            content: .image(png)
        )
        XCTAssertEqual(payload?.typeIdentifier, "public.png")
        XCTAssertEqual(payload?.data, png)
    }
}
