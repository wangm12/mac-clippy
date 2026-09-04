import XCTest

@testable import MacClippyCore

final class MacClippyStorageDashboardPolicyTests: XCTestCase {
    func testDashboardRowsShowUsageAgainstCaps() {
        let rows = MacClippyStorageDashboardPolicy.rows(
            from: MacClippyStorageUsage(
                itemCount: 2_500,
                imageBytes: 512 * 1_024 * 1_024,
                totalBytes: 1_024 * 1_024 * 1_024,
                maxItems: 10_000,
                maxImageBytes: 2_048 * 1_024 * 1_024,
                maxTotalBytes: 4_096 * 1_024 * 1_024
            )
        )

        XCTAssertEqual(rows.map(\.kind), [.items, .images, .total])
        XCTAssertEqual(rows[0].usedLabel, "2,500")
        XCTAssertEqual(rows[0].capLabel, "10,000 items")
        XCTAssertEqual(rows[0].fraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(rows[1].usedLabel, "512 MB")
        XCTAssertEqual(rows[1].capLabel, "2 GB")
        XCTAssertEqual(rows[2].usedLabel, "1 GB")
        XCTAssertEqual(rows[2].capLabel, "4 GB")
        XCTAssertEqual(rows[2].fraction, 0.25, accuracy: 0.0001)
    }

    func testCompressSkipsPinnedRecentTinyAndAlreadySmallImages() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-8 * 24 * 60 * 60)

        XCTAssertFalse(
            MacClippyStorageDashboardPolicy.shouldCompress(
                isProtected: true,
                modified: old,
                now: now,
                byteCount: 1_000_000,
                longestEdge: 4_000
            )
        )
        XCTAssertFalse(
            MacClippyStorageDashboardPolicy.shouldCompress(
                isProtected: false,
                modified: now.addingTimeInterval(-3_600),
                now: now,
                byteCount: 1_000_000,
                longestEdge: 4_000
            )
        )
        XCTAssertFalse(
            MacClippyStorageDashboardPolicy.shouldCompress(
                isProtected: false,
                modified: old,
                now: now,
                byteCount: 8_000,
                longestEdge: 4_000
            )
        )
        XCTAssertFalse(
            MacClippyStorageDashboardPolicy.shouldCompress(
                isProtected: false,
                modified: old,
                now: now,
                byteCount: 1_000_000,
                longestEdge: 800
            )
        )
        XCTAssertTrue(
            MacClippyStorageDashboardPolicy.shouldCompress(
                isProtected: false,
                modified: old,
                now: now,
                byteCount: 1_000_000,
                longestEdge: 4_000
            )
        )
    }

    func testWorthReplacingRequiresMeaningfulSavings() {
        XCTAssertFalse(
            MacClippyStorageDashboardPolicy.isWorthReplacing(
                originalBytes: 1_000,
                compressedBytes: 950
            )
        )
        XCTAssertTrue(
            MacClippyStorageDashboardPolicy.isWorthReplacing(
                originalBytes: 1_000_000,
                compressedBytes: 400_000
            )
        )
    }

    func testCompressMessageSummarizesSavings() {
        XCTAssertEqual(
            MacClippyStorageDashboardPolicy.compressMessage(
                compressedCount: 0,
                bytesSaved: 0
            ),
            "No old images needed compression."
        )
        XCTAssertEqual(
            MacClippyStorageDashboardPolicy.compressMessage(
                compressedCount: 3,
                bytesSaved: 12 * 1_024 * 1_024
            ),
            "Compressed 3 old image(s) and freed 12 MB."
        )
    }
}
