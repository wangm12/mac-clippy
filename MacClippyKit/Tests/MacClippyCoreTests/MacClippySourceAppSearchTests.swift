import CryptoKit
import XCTest

@testable import MacClippyCore

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

    func testStructuredQueryPushesAppClauseOntoTheSourceAppFilter() {
        let filter = MacClippyClipboardMetadataFilter.fromStructuredQuery(
            MacClippySearchGrammar.parse("app:微信 type:url")
        )
        XCTAssertEqual(filter.sourceAppContains, ["微信"])
    }

    func testListAppFilterMatchesStoredDisplayNameWithoutAFullScanFallback() throws {
        let store = try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: SymmetricKey(data: Data(repeating: 9, count: 32)),
            deviceID: XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
        let weChat = try store.append(
            .text("from wechat"),
            sourceAppBundleID: "com.tencent.xinWeChat",
            sourceAppDisplayName: "微信"
        )
        _ = try store.append(
            .text("from safari"),
            sourceAppBundleID: "com.apple.Safari",
            sourceAppDisplayName: "Safari"
        )

        let hits = try store.list(
            limit: 10,
            filter: MacClippyClipboardMetadataFilter.fromStructuredQuery(
                MacClippySearchGrammar.parse("app:微信")
            )
        )
        XCTAssertEqual(hits.map(\.id), [weChat.id])
    }

    func testListAppFilterDoesNotMatchNullDisplayNamesFromOtherApps() throws {
        let store = try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: SymmetricKey(data: Data(repeating: 9, count: 32)),
            deviceID: XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
        let safari = try store.append(
            .text("from safari"),
            sourceAppBundleID: "com.apple.Safari",
            sourceAppDisplayName: "Safari"
        )
        _ = try store.append(
            .text("from chrome without a stored display name"),
            sourceAppBundleID: "com.google.Chrome"
        )

        let hits = try store.list(
            limit: 10,
            filter: MacClippyClipboardMetadataFilter.fromStructuredQuery(
                MacClippySearchGrammar.parse("app:Safari")
            )
        )
        XCTAssertEqual(hits.map(\.id), [safari.id])
    }

    func testPreferredDisplayNameKeepsTheStoredLocalizedName() {
        XCTAssertEqual(
            MacClippySourceAppSearch.preferredDisplayName(
                stored: "微信",
                resolved: "xinWeChat"
            ),
            "微信"
        )
        XCTAssertEqual(
            MacClippySourceAppSearch.preferredDisplayName(
                stored: "Unknown source",
                resolved: "Safari"
            ),
            "Safari"
        )
        XCTAssertEqual(
            MacClippySourceAppSearch.preferredDisplayName(
                stored: nil,
                resolved: "Safari"
            ),
            "Safari"
        )
    }

    func testListExposesTheStoredSourceAppDisplayName() throws {
        let store = try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: SymmetricKey(data: Data(repeating: 9, count: 32)),
            deviceID: XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
        let weChat = try store.append(
            .text("from wechat"),
            sourceAppBundleID: "com.tencent.xinWeChat",
            sourceAppDisplayName: "微信"
        )
        XCTAssertEqual(try store.list(limit: 1).first?.sourceAppDisplayName, "微信")
        XCTAssertEqual(try store.metas(for: [weChat.id]).first?.sourceAppDisplayName, "微信")
    }
}
