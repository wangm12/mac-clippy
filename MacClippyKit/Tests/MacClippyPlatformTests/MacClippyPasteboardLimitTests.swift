import Foundation
import XCTest

import MacClippyCore
import MacClippyPlatform

final class MacClippyPasteboardLimitTests: XCTestCase {
    func testOversizedRepresentationIsRetainedAsTypeOnlyAndNeverRetried() {
        let change = PasteboardChange(
            changeCount: 12,
            items: [PasteboardItem(
                types: ["com.example.large"],
                oversizedTypes: ["com.example.large"]
            )]
        )

        let representations = MacClippyCaptureMapper.representations(for: change)
        XCTAssertEqual(representations.count, 1)
        XCTAssertEqual(representations[0].payloadState, .oversized)
        XCTAssertTrue(representations[0].payloadBytes == nil)
        XCTAssertTrue(MacClippyPasteboardAvailability.unavailableTypes(in: change).isEmpty)
    }

    func testChangeTracksInputItemTruncationWithoutChangingGeneration() {
        let change = PasteboardChange(
            changeCount: 4,
            items: [PasteboardItem(types: ["public.utf8-plain-text"])],
            truncatedItemCount: 3
        )
        XCTAssertEqual(change.changeCount, 4)
        XCTAssertEqual(change.truncatedItemCount, 3)
    }
}
