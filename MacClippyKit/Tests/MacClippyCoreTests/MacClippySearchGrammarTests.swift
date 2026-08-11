import Foundation
import XCTest

import MacClippyCore

// P2b focused tests for the pure structured search grammar: tokenization,
// quoting, date parsing, invalid-clause degradation, conjunction semantics,
// and predicate evaluation against MacClippySearchRecord. The runtime/dock
// integration is covered by the app test target (MacClippySearchGrammarTests)
// because it needs the runtime's private search store.
final class MacClippySearchGrammarTests: XCTestCase {

    // MARK: - Tokenization

    func testEmptyQueryYieldsEmptyQuery() {
        let q = MacClippySearchGrammar.parse("")
        XCTAssertTrue(q.bareTerms.isEmpty)
        XCTAssertTrue(q.clauses.isEmpty)
        XCTAssertFalse(q.hasStructuredClauses)
        XCTAssertFalse(q.isStructuredOnly)
    }

    func testWhitespaceOnlyQueryYieldsEmptyQuery() {
        let q = MacClippySearchGrammar.parse("   \n  \t ")
        XCTAssertTrue(q.bareTerms.isEmpty)
        XCTAssertTrue(q.clauses.isEmpty)
    }

    func testBareTermsAreCollectedInOrder() {
        let q = MacClippySearchGrammar.parse("hello world foo")
        XCTAssertEqual(q.bareTerms, ["hello", "world", "foo"])
        XCTAssertTrue(q.clauses.isEmpty)
        XCTAssertFalse(q.hasStructuredClauses)
    }

    func testBareTermWithColonButUnknownKeyDegradesToBare() {
        // foo:bar is an unknown key; it must NOT be dropped and must NOT
        // broaden. It degrades to a bare term so FTS still narrows.
        let q = MacClippySearchGrammar.parse("foo:bar")
        XCTAssertEqual(q.bareTerms, ["foo:bar"])
        XCTAssertTrue(q.clauses.isEmpty)
        XCTAssertFalse(q.hasStructuredClauses)
    }

    // MARK: - Quoting

    func testQuotedValueWithSpacesIsOneBareTerm() {
        let q = MacClippySearchGrammar.parse("\"project alpha\"")
        XCTAssertEqual(q.bareTerms, ["project alpha"])
        XCTAssertTrue(q.clauses.isEmpty)
    }

    func testTagClauseAcceptsQuotedValueWithSpaces() {
        let q = MacClippySearchGrammar.parse("tag:\"project alpha\"")
        XCTAssertEqual(q.clauses, [.label("project alpha")])
        XCTAssertTrue(q.bareTerms.isEmpty)
        XCTAssertTrue(q.isStructuredOnly)
    }

    func testLabelClauseAcceptsQuotedValueWithEscapedQuote() {
        let q = MacClippySearchGrammar.parse("label:\"a \\\"b\\\" c\"")
        XCTAssertEqual(q.clauses, [.label("a \"b\" c")])
    }

    func testAppClauseAcceptsQuotedValue() {
        let q = MacClippySearchGrammar.parse("app:\"com.example app\"")
        XCTAssertEqual(q.clauses, [.app("com.example app")])
    }

    func testUnterminatedQuoteConsumesRestAsBareTerm() {
        // An unterminated quote must not crash. The whole malformed token
        // degrades to a bare free-text term (per the malformed-clause safety
        // rule) so the query narrows via FTS instead of producing a clause
        // with a stray quote in its value.
        let q = MacClippySearchGrammar.parse("tag:\"unfinished")
        XCTAssertEqual(q.bareTerms, ["tag:\"unfinished"])
        XCTAssertTrue(q.clauses.isEmpty)
    }

    // MARK: - Known clauses

    func testTypeClauseParsesEachKnownKind() {
        for kind in [MacClippyContentKind.text, .html, .rtf, .image, .files] {
            let q = MacClippySearchGrammar.parse("type:\(kind.rawValue)")
            XCTAssertEqual(q.clauses, [.type(kind)], "kind \(kind.rawValue) should parse")
            XCTAssertTrue(q.isStructuredOnly)
        }
    }

    func testTypeClauseUnknownKindDegradesToBare() {
        let q = MacClippySearchGrammar.parse("type:audio")
        XCTAssertEqual(q.bareTerms, ["type:audio"])
        XCTAssertTrue(q.clauses.isEmpty)
    }

    func testNameAndLegacyAliasesAreEquivalent() {
        let name = MacClippySearchGrammar.parse("name:work")
        let tag = MacClippySearchGrammar.parse("tag:work")
        let label = MacClippySearchGrammar.parse("label:work")
        XCTAssertEqual(name.clauses, [.label("work")])
        XCTAssertEqual(tag.clauses, [.label("work")])
        XCTAssertEqual(label.clauses, [.label("work")])
    }

    func testHasNameAndHasOCRClauses() {
        let query = MacClippySearchGrammar.parse("has:name has:ocr")
        XCTAssertEqual(query.clauses, [.hasLabel, .hasOCR])
    }

    func testHasUnknownValueDegradesToBare() {
        let q = MacClippySearchGrammar.parse("has:foo")
        XCTAssertEqual(q.bareTerms, ["has:foo"])
        XCTAssertTrue(q.clauses.isEmpty)
    }

    func testEmptyValueDegradesToBare() {
        // app: with no value must not match everything.
        let q = MacClippySearchGrammar.parse("app: tag:")
        XCTAssertEqual(q.bareTerms, ["app:", "tag:"])
        XCTAssertTrue(q.clauses.isEmpty)
    }

    func testEmptyKeyDegradesToBare() {
        let q = MacClippySearchGrammar.parse(":foo")
        XCTAssertEqual(q.bareTerms, [":foo"])
        XCTAssertTrue(q.clauses.isEmpty)
    }

    // MARK: - Dates

    func testBeforeAndAfterClausesParseDayStart() {
        let before = MacClippySearchGrammar.parse("before:2026-07-21")
        let after = MacClippySearchGrammar.parse("after:2026-07-21")
        guard case let .before(date) = before.clauses.first else {
            return XCTFail("expected .before clause, got \(before.clauses)")
        }
        guard case let .after(afterDate) = after.clauses.first else {
            return XCTFail("expected .after clause, got \(after.clauses)")
        }
        // Both resolve to the start of the same local day.
        XCTAssertEqual(startOfDay(date), date)
        XCTAssertEqual(startOfDay(afterDate), afterDate)
        XCTAssertEqual(date, afterDate)
    }

    func testInvalidDateDegradesToBare() {
        for bad in ["before:2026-13-40", "after:not-a-date", "before:2026/07/21", "before:2026-7-1", "before:20260721"] {
            let q = MacClippySearchGrammar.parse(bad)
            // An invalid date must degrade to a bare term, never a structured
            // clause, so the query narrows via FTS instead of broadening.
            XCTAssertTrue(q.clauses.isEmpty, "bad date \(bad) should not produce a structured clause")
            XCTAssertEqual(q.bareTerms, [bad], "bad date \(bad) should degrade to a bare term")
        }
    }

    // MARK: - Conjunctions

    func testStructuredClausesAndBareTermsAreCollectedSeparately() {
        let q = MacClippySearchGrammar.parse("important type:text app:com.example tag:work after:2026-01-01")
        XCTAssertEqual(q.bareTerms, ["important"])
        XCTAssertEqual(q.clauses, [
            .type(.text),
            .app("com.example"),
            .label("work"),
            .after(startOfDay(parseStrict("2026-01-01")!))
        ])
        XCTAssertTrue(q.hasStructuredClauses)
        XCTAssertFalse(q.isStructuredOnly)
    }

    func testStructuredOnlyQueryFlaggedCorrectly() {
        let q = MacClippySearchGrammar.parse("type:image has:label")
        XCTAssertTrue(q.isStructuredOnly)
        XCTAssertTrue(q.bareTerms.isEmpty)
    }

    // MARK: - Predicates

    private func record(
        kind: MacClippyContentKind = .text,
        app: String? = nil,
        label: String? = nil,
        ocr: String? = nil,
        modified: Date = Date(timeIntervalSince1970: 1_783_728_000) // 2026-07-09 12:00 UTC
    ) -> MacClippySearchGrammar.SearchRecord {
        MacClippySearchGrammar.SearchRecord(
            contentKind: kind, sourceAppBundleID: app, customLabel: label, ocrText: ocr, modified: modified
        )
    }

    func testPredicateTypeMatchesExactKind() {
        let r = record(kind: .image)
        XCTAssertTrue(MacClippySearchGrammar.matches(.type(.image), record: r))
        XCTAssertFalse(MacClippySearchGrammar.matches(.type(.text), record: r))
        XCTAssertFalse(MacClippySearchGrammar.matches(.type(.files), record: r))
    }

    func testPredicateAppIsCaseInsensitiveSubstring() {
        let r = record(app: "com.Example.Editor")
        XCTAssertTrue(MacClippySearchGrammar.matches(.app("example"), record: r))
        XCTAssertTrue(MacClippySearchGrammar.matches(.app("EDITOR"), record: r))
        XCTAssertTrue(MacClippySearchGrammar.matches(.app("com.example"), record: r))
        XCTAssertFalse(MacClippySearchGrammar.matches(.app("com.other"), record: r))
    }

    func testPredicateAppNilNeverMatches() {
        let r = record(app: nil)
        XCTAssertFalse(MacClippySearchGrammar.matches(.app("anything"), record: r))
    }

    func testPredicateLabelIsCaseInsensitiveSubstringOnCustomLabel() {
        let r = record(label: "Project Alpha")
        XCTAssertTrue(MacClippySearchGrammar.matches(.label("project"), record: r))
        XCTAssertTrue(MacClippySearchGrammar.matches(.label("ALPHA"), record: r))
        XCTAssertFalse(MacClippySearchGrammar.matches(.label("beta"), record: r))
    }

    func testPredicateLabelNilNeverMatches() {
        let r = record(label: nil)
        XCTAssertFalse(MacClippySearchGrammar.matches(.label("anything"), record: r))
    }

    func testPredicateHasLabelRequiresNonBlankCustomLabel() {
        let withLabel = record(label: "kept")
        let blankLabel = record(label: "   ")
        let nilLabel = record(label: nil)
        XCTAssertTrue(MacClippySearchGrammar.matches(.hasLabel, record: withLabel))
        XCTAssertFalse(MacClippySearchGrammar.matches(.hasLabel, record: blankLabel))
        XCTAssertFalse(MacClippySearchGrammar.matches(.hasLabel, record: nilLabel))
    }

    func testPredicateHasOCRRequiresNonBlankOCRText() {
        let withOCR = record(ocr: "scanned text")
        let blankOCR = record(ocr: "  \n ")
        let nilOCR = record(ocr: nil)
        XCTAssertTrue(MacClippySearchGrammar.matches(.hasOCR, record: withOCR))
        XCTAssertFalse(MacClippySearchGrammar.matches(.hasOCR, record: blankOCR))
        XCTAssertFalse(MacClippySearchGrammar.matches(.hasOCR, record: nilOCR))
    }

    func testPredicateBeforeIsStrictlyBeforeDayStart() {
        // Day start for 2026-07-10 in the local calendar.
        let dayStart = startOfDay(parseStrict("2026-07-10")!)
        let earlier = record(modified: dayStart.addingTimeInterval(-1))
        let atStart = record(modified: dayStart)
        let later = record(modified: dayStart.addingTimeInterval(60))
        XCTAssertTrue(MacClippySearchGrammar.matches(.before(dayStart), record: earlier))
        XCTAssertFalse(MacClippySearchGrammar.matches(.before(dayStart), record: atStart))
        XCTAssertFalse(MacClippySearchGrammar.matches(.before(dayStart), record: later))
    }

    func testPredicateAfterIsOnOrAfterDayStart() {
        let dayStart = startOfDay(parseStrict("2026-07-10")!)
        let earlier = record(modified: dayStart.addingTimeInterval(-1))
        let atStart = record(modified: dayStart)
        let later = record(modified: dayStart.addingTimeInterval(60))
        XCTAssertFalse(MacClippySearchGrammar.matches(.after(dayStart), record: earlier))
        XCTAssertTrue(MacClippySearchGrammar.matches(.after(dayStart), record: atStart))
        XCTAssertTrue(MacClippySearchGrammar.matches(.after(dayStart), record: later))
    }

    func testQueryMatchesANDsAllStructuredClauses() {
        // All clauses match -> true; one failing clause -> false.
        let r = record(kind: .text, app: "com.example.Editor", label: "Project Alpha", ocr: nil, modified: parseStrict("2026-07-15")!)
        let allMatch = MacClippySearchGrammar.Query(clauses: [
            .type(.text), .app("example"), .label("alpha"), .after(startOfDay(parseStrict("2026-07-01")!))
        ])
        XCTAssertTrue(MacClippySearchGrammar.matches(allMatch, record: r))

        let kindFails = MacClippySearchGrammar.Query(clauses: [
            .type(.image), .app("example")
        ])
        XCTAssertFalse(MacClippySearchGrammar.matches(kindFails, record: r))

        let appFails = MacClippySearchGrammar.Query(clauses: [
            .type(.text), .app("com.other")
        ])
        XCTAssertFalse(MacClippySearchGrammar.matches(appFails, record: r))

        let dateFails = MacClippySearchGrammar.Query(clauses: [
            .before(startOfDay(parseStrict("2026-07-01")!))
        ])
        XCTAssertFalse(MacClippySearchGrammar.matches(dateFails, record: r))
    }

    func testQueryMatchesIgnoresBareClauses() {
        // Bare clauses are not evaluated by the predicate; they are handled by
        // FTS at the runtime layer. A query with only bare clauses matches
        // every record so the predicate never narrows FTS-bound results.
        let r = record()
        let q = MacClippySearchGrammar.Query(clauses: [.bare("anything"), .bare("else")])
        XCTAssertTrue(MacClippySearchGrammar.matches(q, record: r))
        XCTAssertFalse(q.hasStructuredClauses)
    }

    // MARK: - Helpers

    private func parseStrict(_ yyyy_mm_dd: String) -> Date? {
        let parts = yyyy_mm_dd.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 0, minute: 0, second: 0))
    }

    private func startOfDay(_ date: Date) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        return calendar.startOfDay(for: date)
    }
}
