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
}
