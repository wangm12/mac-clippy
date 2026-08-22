import XCTest

import MacClippyCore

final class MacClippySourceAppSearchTests: XCTestCase {
    func testSegmentsIncludeBundleIDAndLastComponent() {
        XCTAssertEqual(
            MacClippySourceAppSearch.segments(bundleID: "com.apple.Safari", displayName: nil),
            ["com.apple.Safari", "Safari"]
        )
    }

    func testSegmentsDedupDisplayNameThatMatchesLastComponent() {
        XCTAssertEqual(
            MacClippySourceAppSearch.segments(bundleID: "com.apple.Safari", displayName: "Safari"),
            ["com.apple.Safari", "Safari"]
        )
        XCTAssertEqual(
            MacClippySourceAppSearch.segments(bundleID: "com.apple.Safari", displayName: "safari"),
            ["com.apple.Safari", "Safari"]
        )
    }

    func testSegmentsKeepDistinctLocalizedDisplayName() {
        XCTAssertEqual(
            MacClippySourceAppSearch.segments(
                bundleID: "com.tencent.xinWeChat",
                displayName: "微信"
            ),
            ["com.tencent.xinWeChat", "xinWeChat", "微信"]
        )
        XCTAssertEqual(
            MacClippySourceAppSearch.segments(
                bundleID: "com.apple.MobileSMS",
                displayName: "Messages"
            ),
            ["com.apple.MobileSMS", "MobileSMS", "Messages"]
        )
    }

    func testSegmentsSkipUnknownPlaceholderAndEmptyValues() {
        XCTAssertEqual(
            MacClippySourceAppSearch.segments(bundleID: nil, displayName: "Unknown source"),
            []
        )
        XCTAssertEqual(
            MacClippySourceAppSearch.segments(bundleID: "  ", displayName: "   "),
            []
        )
    }
}
