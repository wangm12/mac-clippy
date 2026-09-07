import XCTest

@testable import MacClippyCore

final class MacClippyThumbnailCachePolicyTests: XCTestCase {
    func testDefaultThumbnailSizeIs480() {
        XCTAssertEqual(MacClippyThumbnailCachePolicy.defaultMaxPixelSize, 480)
    }

    func testVisibleCardsAreTheOnlyOnesDecoded() {
        XCTAssertTrue(MacClippyThumbnailCachePolicy.shouldDecode(isCardVisible: true))
        XCTAssertFalse(MacClippyThumbnailCachePolicy.shouldDecode(isCardVisible: false))
    }

    func testFileNameIsStableForTheSameRecordAndSize() {
        let id = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        XCTAssertEqual(
            MacClippyThumbnailCachePolicy.fileName(recordID: id, maxPixelSize: 480),
            MacClippyThumbnailCachePolicy.fileName(recordID: id, maxPixelSize: 480)
        )
        XCTAssertNotEqual(
            MacClippyThumbnailCachePolicy.fileName(recordID: id, maxPixelSize: 480),
            MacClippyThumbnailCachePolicy.fileName(recordID: id, maxPixelSize: 32)
        )
    }

    func testTaskRestartKeepsPixelsWhenIdentityIsUnchanged() {
        XCTAssertFalse(
            MacClippyThumbnailCachePolicy.shouldClearDisplayedImage(
                displayedIdentity: "file:///tmp/clip.mp4|96x96",
                loadingIdentity: "file:///tmp/clip.mp4|96x96"
            )
        )
    }

    func testIdentityChangeClearsDisplayedImage() {
        XCTAssertTrue(
            MacClippyThumbnailCachePolicy.shouldClearDisplayedImage(
                displayedIdentity: "file:///tmp/a.mp4|96x96",
                loadingIdentity: "file:///tmp/b.mp4|96x96"
            )
        )
        XCTAssertTrue(
            MacClippyThumbnailCachePolicy.shouldClearDisplayedImage(
                displayedIdentity: nil,
                loadingIdentity: "file:///tmp/b.mp4|96x96"
            )
        )
    }
}
