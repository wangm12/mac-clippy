import Foundation
import XCTest

import MacClippyCore

final class MacClippySearchQueryTests: XCTestCase {
    func testFTSMatchQueryKeepsQuotedPhrasesAsOneToken() {
        XCTAssertEqual(
            MacClippySearchQuery.ftsMatchQuery(from: ["project alpha", "memo"]),
            "\"project alpha\" \"memo\""
        )
    }

    func testFTSMatchQueryEmitsPrefixStarOutsideQuotes() {
        XCTAssertEqual(
            MacClippySearchQuery.ftsMatchQuery(from: ["clip*"]),
            "\"clip\"*"
        )
    }

    func testCJKAndFTSTermsAreSplit() {
        XCTAssertEqual(MacClippySearchQuery.cjkTerms(in: ["你好世界"]), ["你好世界"])
        XCTAssertEqual(MacClippySearchQuery.cjkTerms(in: ["hello", "世界"]), ["世界"])
        XCTAssertEqual(MacClippySearchQuery.ftsTerms(in: ["hello", "世界"]), ["hello"])
        XCTAssertTrue(MacClippySearchQuery.cjkTerms(in: ["hello", "world"]).isEmpty)
        XCTAssertEqual(MacClippySearchQuery.ftsTerms(in: ["clip*"]), ["clip*"])
    }

    func testLikePatternsEscapeWildcards() {
        XCTAssertEqual(
            MacClippySearchQuery.likePatterns(for: ["100%", "a_b"]),
            ["%100\\%%", "%a\\_b%"]
        )
    }

    func testFTSSnippetMarkersAreStrippedForDisplay() {
        XCTAssertEqual(
            MacClippySearchQuery.displayText(fromFTSSnippet: "foo \u{001E}hello\u{001F} bar"),
            "foo hello bar"
        )
        XCTAssertEqual(
            MacClippySearchQuery.displayText(fromFTSSnippet: "foo <hello> bar"),
            "foo hello bar"
        )
        XCTAssertEqual(
            MacClippySearchQuery.displayText(fromFTSSnippet: "<div class=\"x\">hello</div>"),
            "<div class=\"x\">hello</div>"
        )
    }

    func testHighlightRangesCoverQueryTermsCaseInsensitively() {
        let text = "Hello clipboard world"
        let ranges = MacClippySearchQuery.highlightedRanges(in: text, queryTerms: ["CLIP"])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(text[ranges[0]]), "clip")
    }

    func testHighlightRangesMergeOverlappingTerms() {
        let text = "helloello"
        let ranges = MacClippySearchQuery.highlightedRanges(in: text, queryTerms: ["hell", "ello"])
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(String(text[ranges[0]]), "helloello")
    }

    func testAllTermsRequireEveryNeedleInSomeHaystack() {
        XCTAssertTrue(
            MacClippySearchQuery.allTerms(["Hello", "clip*"], appearIn: ["hello clipboard"])
        )
        XCTAssertFalse(
            MacClippySearchQuery.allTerms(["hello", "missing"], appearIn: ["hello clipboard"])
        )
    }
}
