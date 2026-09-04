import XCTest

@testable import MacClippyCore

final class MacClippyDockPageLoadPolicyTests: XCTestCase {
    func testCardsWithAStoredKindCanBeProjectedFromMetadata() {
        XCTAssertTrue(MacClippyDockPageLoadPolicy.canProjectFromMetadata(contentKind: .text))
        XCTAssertTrue(MacClippyDockPageLoadPolicy.canProjectFromMetadata(contentKind: .image))
        XCTAssertTrue(MacClippyDockPageLoadPolicy.canProjectFromMetadata(contentKind: .files))
        XCTAssertFalse(MacClippyDockPageLoadPolicy.canProjectFromMetadata(contentKind: nil))
    }

    func testImagePixelSizeParsesThePersistedPreview() {
        XCTAssertEqual(
            MacClippyDockPageLoadPolicy.imagePixelSize(fromPreview: "(image 12x34)").map { [$0.width, $0.height] },
            [12, 34]
        )
        XCTAssertNil(MacClippyDockPageLoadPolicy.imagePixelSize(fromPreview: "hello"))
    }

    func testFileURLsAreRecoverableFromThePersistedPreview() {
        let urls = [URL(fileURLWithPath: "/tmp/clip.pdf")]
        let stored = MacClippyFilePresentation.persistPreview(for: urls)
        XCTAssertEqual(MacClippyDockPageLoadPolicy.fileURLs(fromPreview: stored), urls)
        XCTAssertEqual(MacClippyDockPageLoadPolicy.fileURLs(fromPreview: "clip.pdf"), [])
    }
}
