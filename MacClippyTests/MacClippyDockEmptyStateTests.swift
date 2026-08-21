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

    func testSnippetEmptyCopyExplainsStructuredFilters() {
        XCTAssertEqual(
            MacClippyDockEmptyStateCopy.snippetTitle(query: "type:text"),
            "Filters apply to History and Pinboard"
        )
        XCTAssertEqual(
            MacClippyDockEmptyStateCopy.snippetSubtitle(query: "type:image"),
            "Snippets match name and trigger text. type: and date filters are not used here."
        )
        XCTAssertEqual(
            MacClippyDockEmptyStateCopy.snippetTitle(query: "hello type:text"),
            "No matching snippets"
        )
        XCTAssertEqual(
            MacClippyDockEmptyStateCopy.snippetSubtitle(query: "hello type:text"),
            "Try a different search."
        )
    }

    func testSearchAnnouncementWaitsForLoadingAndReportsMoreAvailable() {
        XCTAssertNil(
            MacClippyDockSearchAnnouncementPolicy.announcement(
                query: "clip",
                tab: .history,
                count: 16,
                hasMore: true,
                isLoading: true
            )
        )
        XCTAssertEqual(
            MacClippyDockSearchAnnouncementPolicy.announcement(
                query: "clip",
                tab: .history,
                count: 16,
                hasMore: true,
                isLoading: false
            ),
            "16 clipboard results, more available"
        )
        XCTAssertEqual(
            MacClippyDockSearchAnnouncementPolicy.announcement(
                query: "clip",
                tab: .history,
                count: 1,
                hasMore: false,
                isLoading: false
            ),
            "1 clipboard result"
        )
        XCTAssertNil(
            MacClippyDockSearchAnnouncementPolicy.announcement(
                query: "",
                tab: .history,
                count: 16,
                hasMore: false,
                isLoading: false
            )
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
