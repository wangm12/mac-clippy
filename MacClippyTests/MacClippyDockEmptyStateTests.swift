import SwiftUI
import XCTest

@testable import MacClippy

final class MacClippyDockEmptyStateTests: XCTestCase {
    func testEmptyStateCopyUsesNoMatchesWhenQueryIsPresent() {
        XCTAssertEqual(
            MacClippyDockEmptyStateCopy.title(hasQuery: true, isPinboard: true, pinboardName: "Work"),
            "No matches"
        )
        XCTAssertEqual(
            MacClippyDockEmptyStateCopy.subtitle(hasQuery: true, isPinboard: true),
            "Try a different search."
        )
        XCTAssertEqual(
            MacClippyDockEmptyStateCopy.title(hasQuery: false, isPinboard: true, pinboardName: "Work"),
            "Work is empty"
        )
        XCTAssertEqual(
            MacClippyDockEmptyStateCopy.title(
                hasQuery: true,
                isPinboard: false,
                pinboardName: nil,
                conflictingTypes: true
            ),
            "Incompatible type filters"
        )
        XCTAssertEqual(
            MacClippyDockEmptyStateCopy.subtitle(
                hasQuery: true,
                isPinboard: false,
                conflictingTypes: true
            ),
            "Remove extra type: filters and search again."
        )
    }

    func testCardHeightGrowsForAccessibilityDynamicType() {
        XCTAssertGreaterThan(
            MacClippyDockCardMetrics.height(for: .accessibility3),
            MacClippyDockCardMetrics.height
        )
        XCTAssertEqual(
            MacClippyDockCardMetrics.height(for: .medium),
            MacClippyDockCardMetrics.height
        )
    }
}
