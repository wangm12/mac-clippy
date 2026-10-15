import MacClippyCore
import XCTest

final class MacClippySearchWorkflowTests: XCTestCase {
    func testFilterReplacementDoesNotAbsorbConditionsIntoUnfinishedText() {
        for text in ["\"invoice", "invoice\\", "\"escaped \\\" quote"] {
            let query = MacClippySearchWorkflowPolicy.composing(text, clauses: [.type(.image), .app("Safari")])
            let changed = MacClippySearchWorkflowPolicy.replacing(.contentType, with: .url, in: query)
            let parsed = MacClippySearchGrammar.parse(changed)
            XCTAssertEqual(MacClippySearchWorkflowPolicy.keywords(in: changed), text)
            XCTAssertTrue(parsed.clauses.contains(.url))
            XCTAssertTrue(parsed.clauses.contains(.app("Safari")))
            XCTAssertEqual(parsed.clauses.count, 2)
        }
    }

    func testDateFieldsRejectExtraTokensAndMalformedDates() {
        let invalid = ["bad app:Terminal", "2026-01-01 app:Terminal", "\"2026-01-01\"",
                       "2026-02-30", "2026-2-01", "2026-13-01", "2026-01-01\napp:Safari"]
        for group in [MacClippySearchWorkflowPolicy.Group.before, .after] {
            for input in invalid {
                XCTAssertThrowsError(try MacClippySearchWorkflowPolicy.dateClause(input, for: group)) {
                    XCTAssertEqual($0 as? MacClippySearchWorkflowPolicy.DateFilterError, .invalidDate)
                }
            }
        }
    }

    func testDateFieldsAcceptValidDatesAndEmptyRemoval() throws {
        for group in [MacClippySearchWorkflowPolicy.Group.before, .after] {
            XCTAssertNil(try MacClippySearchWorkflowPolicy.dateClause(" \n ", for: group))
            let clause = try MacClippySearchWorkflowPolicy.dateClause(" 2024-02-29 ", for: group)
            let query = MacClippySearchWorkflowPolicy.replacing(group, with: clause, in: "invoice app:Safari type:text")
            let parsed = MacClippySearchGrammar.parse(query)
            XCTAssertEqual(parsed.bareTerms, ["invoice"])
            XCTAssertEqual(parsed.clauses.count, 3)
            XCTAssertTrue(parsed.clauses.contains(.app("Safari")))
            XCTAssertTrue(parsed.clauses.contains(.type(.text)))
            switch (group, clause) {
            case (.before, .before), (.after, .after): break
            default: XCTFail("Date clause did not match its field")
            }
        }
    }

    func testTypeFilterReplacementKeepsKeywordsAndOtherConditions() {
        let raw = "\"invoice number\" type:image app:Safari has:ocr"
        let result = MacClippySearchWorkflowPolicy.replacing(.contentType, with: .url, in: raw)
        let parsed = MacClippySearchGrammar.parse(result)
        XCTAssertEqual(parsed.bareTerms, ["invoice number"])
        XCTAssertEqual(parsed.clauses, [.app("Safari"), .hasOCR, .url])
    }

    func testClearFiltersKeepsQuotedWordsAndMalformedClauses() {
        let raw = "\"two words\" type:unknown app:Safari after:2026-01-01"
        XCTAssertEqual(
            MacClippySearchGrammar.parse(MacClippySearchWorkflowPolicy.clearingFilters(in: raw)).bareTerms,
            ["two words", "type:unknown"])
    }

    func testRemovingSourceDoesNotRemoveTypeOrDates() {
        let result = MacClippySearchWorkflowPolicy.replacing(
            .source, with: nil,
            in: "receipt app:Safari type:text before:2026-02-01")
        let parsed = MacClippySearchGrammar.parse(result)
        XCTAssertEqual(parsed.bareTerms, ["receipt"])
        XCTAssertEqual(parsed.clauses.count, 2)
        XCTAssertTrue(parsed.clauses.contains(.type(.text)))
    }

    func testKeywordProjectionPreservesLiteralQuotesAndMalformedTokens() {
        let raw = "\"app:Safari\" \"two words\" unknown:value app:Mail"
        XCTAssertEqual(
            MacClippySearchWorkflowPolicy.keywords(in: raw), "\"app:Safari\" \"two words\" unknown:value")
    }
}
