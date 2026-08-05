import XCTest

import MacClippyCore
import MacClippyPlatform

final class MacClippySnippetExpansionPlannerTests: XCTestCase {
    func testAutoModeExpandsOnWhitespaceAndSuppressesDelimiter() {
        var planner = planner(mode: .autoExpand)

        typeCharacters(";email", into: &planner)

        XCTAssertEqual(
            planner.handle(" "),
            MacClippySnippetExpansionPlan(
                body: "hello@example.com",
                charactersToDelete: 6,
                suppressCurrentEvent: true
            )
        )
    }

    func testConfirmWithTabExpandsOnlyOnTab() {
        var planner = planner(mode: .confirmWithTab)
        typeCharacters(";email", into: &planner)

        XCTAssertNil(planner.handle(" "))

        typeCharacters(";email", into: &planner)
        XCTAssertEqual(
            planner.handle("\t", keyCode: 48),
            MacClippySnippetExpansionPlan(
                body: "hello@example.com",
                charactersToDelete: 6,
                suppressCurrentEvent: true
            )
        )
    }

    func testDisabledModeNeverExpands() {
        var planner = planner(mode: .disabled)
        typeCharacters(";email", into: &planner)

        XCTAssertNil(planner.handle(" "))
        XCTAssertNil(planner.handle("\t", keyCode: 48))
    }

    func testBufferIsBoundedAndResetsAfterDelimiter() {
        var planner = planner(mode: .autoExpand)
        typeCharacters(";email" + String(repeating: "x", count: 64), into: &planner)

        XCTAssertNil(planner.handle(" "))

        typeCharacters(";email", into: &planner)
        XCTAssertNotNil(planner.handle("\n"))
    }

    func testDisqualifyingModifiersPreventExpansionAndResetBuffer() {
        var planner = planner(mode: .autoExpand)
        typeCharacters(";email", into: &planner)

        XCTAssertNil(planner.handle(" ", hasDisqualifyingModifiers: true))
        typeCharacters(";email", into: &planner)
        XCTAssertNotNil(planner.handle(" "))
    }

    private func planner(mode: MacClippySnippetExpansionMode) -> MacClippySnippetExpansionPlanner {
        MacClippySnippetExpansionPlanner(mode: mode) { trigger in
            trigger == ";email" ? "hello@example.com" : nil
        }
    }

    private func typeCharacters(
        _ string: String,
        into planner: inout MacClippySnippetExpansionPlanner
    ) {
        for character in string {
            XCTAssertNil(planner.handle(character))
        }
    }
}
