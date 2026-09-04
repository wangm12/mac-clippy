import XCTest

@testable import MacClippyCore

final class MacClippySearchFilterChipPolicyTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testStructuredClausesBecomeRemovableChips() {
        let query = MacClippySearchGrammar.parse("invoice type:image has:ocr app:Safari")
        let chips = MacClippySearchFilterChipPolicy.chips(from: query, calendar: utc)
        XCTAssertEqual(chips.map(\.token), ["type:image", "has:ocr", "app:Safari"])
        XCTAssertEqual(chips.map(\.title), ["Image", "Has OCR", "Safari"])
        XCTAssertTrue(chips.allSatisfy { !$0.isSuggestion })
        XCTAssertEqual(
            MacClippySearchFilterChipPolicy.ocrHighlightTerms(from: query),
            ["invoice"]
        )
    }

    func testRemovingAChipLeavesBareTermsAndOtherFilters() {
        let next = MacClippySearchFilterChipPolicy.removing(
            token: "type:image",
            from: "invoice type:image has:ocr"
        )
        XCTAssertEqual(MacClippySearchGrammar.parse(next).bareTerms, ["invoice"])
        XCTAssertEqual(MacClippySearchGrammar.parse(next).clauses, [.hasOCR])
        XCTAssertFalse(next.contains("type:image"))
    }

    func testSuggestionsSkipFiltersAlreadyInTheQuery() {
        let query = MacClippySearchGrammar.parse("type:text")
        let suggestions = MacClippySearchFilterChipPolicy.suggestions(for: query)
        XCTAssertFalse(suggestions.contains { $0.token == "type:text" })
        XCTAssertTrue(suggestions.contains { $0.token == "has:ocr" })
        XCTAssertTrue(suggestions.allSatisfy(\.isSuggestion))
    }

    func testOCRHitSnippetHighlightsTheMatchingRun() {
        XCTAssertNil(
            MacClippySearchFilterChipPolicy.ocrHitSnippet(
                ocrText: "BOARDING PASS",
                terms: []
            )
        )
        XCTAssertEqual(
            MacClippySearchFilterChipPolicy.ocrHitSnippet(
                ocrText: "Left boarding pass right",
                terms: ["boarding"]
            ),
            "Left boarding pass right"
        )
        XCTAssertNil(
            MacClippySearchFilterChipPolicy.ocrHitSnippet(
                ocrText: "no match here",
                terms: ["invoice"]
            )
        )
    }

    func testAppendingASuggestionDoesNotDuplicateAnActiveFilter() {
        XCTAssertEqual(
            MacClippySearchFilterChipPolicy.appending(token: "has:ocr", to: "invoice"),
            "invoice has:ocr"
        )
        XCTAssertEqual(
            MacClippySearchFilterChipPolicy.appending(token: "has:ocr", to: "invoice has:ocr"),
            "invoice has:ocr"
        )
    }

    func testRemovingAChipKeepsQuotedAppValues() {
        let next = MacClippySearchFilterChipPolicy.removing(
            token: "has:ocr",
            from: "has:ocr app:\"Google Chrome\""
        )
        XCTAssertEqual(MacClippySearchGrammar.parse(next).clauses, [.app("Google Chrome")])
        XCTAssertTrue(next.contains("Google Chrome"))
    }
}
