import MacClippyCore
import MacClippyPlatform
import XCTest

final class MacClippySearchEditingEchoTests: XCTestCase {
    func testNativeEditingKeepsTrailingWordSeparatorsUntilExplicitSynchronization() {
        for typed in ["invoice ", "invoice  ", "invoice\t"] {
            XCTAssertFalse(MacClippyDockSearchQueryWritePolicy.shouldApplyExternalStringToFieldEditor(
                hasMarkedText: false, incoming: "invoice", current: typed, isEditing: true))
            XCTAssertTrue(MacClippyDockSearchQueryWritePolicy.shouldApplyExternalStringToFieldEditor(
                hasMarkedText: false, incoming: "invoice", current: typed,
                isEditing: true, programmaticSync: true))
        }
    }

    func testMountedFiltersDoNotTurnNormalizedEchoIntoASeparatorDeletion() {
        let committed = MacClippyDockSearchQueryWritePolicy.committedQuery(
            current: "invoice type:text", incoming: "invoice ", allowEmptyOverwrite: true,
            preservedTokens: ["type:text"])
        let projected = MacClippyDockSearchQueryWritePolicy.displayedSearchText(
            committedQuery: committed, excludingTokens: ["type:text"])
        XCTAssertEqual(projected, "invoice")
        XCTAssertFalse(MacClippyDockSearchQueryWritePolicy.shouldApplyExternalStringToFieldEditor(
            hasMarkedText: false, incoming: projected, current: "invoice ", isEditing: true))
        let continued = MacClippyDockSearchQueryWritePolicy.committedQuery(
            current: committed, incoming: "invoice number", allowEmptyOverwrite: true,
            preservedTokens: ["type:text"])
        let parsed = MacClippySearchGrammar.parse(continued)
        XCTAssertEqual(parsed.bareTerms, ["invoice", "number"])
        XCTAssertEqual(parsed.clauses, [.type(.text)])
    }
}
