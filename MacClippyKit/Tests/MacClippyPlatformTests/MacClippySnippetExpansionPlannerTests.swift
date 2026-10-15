import XCTest
import Carbon.HIToolbox

import MacClippyCore
import MacClippyPlatform

final class MacClippySnippetExpansionPlannerTests: XCTestCase {
    func testAutoModeWaitsForSpaceAfterTheCompleteTrigger() {
        var planner = planner(mode: .autoExpand)
        typeCharacters(";email", into: &planner)

        XCTAssertEqual(
            planner.handle(" "),
            MacClippySnippetExpansionPlan(
                body: "hello@example.com",
                charactersToDelete: 7,
                suppressCurrentEvent: false
            )
        )
        XCTAssertNil(planner.handle(" "), "a completed expansion must not fire twice")
    }

    func testAutoModePassesWhitespaceAndIncludesItInTheExpansionCommit() {
        var planner = planner(mode: .autoExpand)

        typeCharacters(";email", into: &planner)

        XCTAssertEqual(
            planner.handle(" "),
            MacClippySnippetExpansionPlan(
                body: "hello@example.com",
                charactersToDelete: 7,
                suppressCurrentEvent: false,
                suppressedDelimiterKeyCode: nil
            )
        )
    }

    func testAutoModeDoesNotExpandOnReturnTabOrOtherWhitespace() {
        var planner = planner(mode: .autoExpand)
        for delimiter in [Character("\n"), "\r", "\t", "\u{00a0}"] {
            typeCharacters(";email", into: &planner)
            XCTAssertNil(planner.handle(delimiter))
            XCTAssertNil(planner.handle(" "), "other delimiters must reset the pending trigger")
        }
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
                suppressCurrentEvent: true,
                suppressedDelimiterKeyCode: UInt16(kVK_Tab)
            )
        )
    }

    func testSharedPrefixDoesNotPreventTypingLongerTrigger() {
        let snapshot = MacClippySnippetLookupSnapshot()
        snapshot.replace(with: [
            Snippet(name: "Short", body: "short", trigger: ";out"),
            Snippet(name: "Long", body: "long", trigger: ";outlook")
        ])
        var planner = MacClippySnippetExpansionPlanner(
            mode: .autoExpand,
            lookup: { snapshot.body(for: $0) }
        )
        typeCharacters(";outlook", into: &planner)
        XCTAssertEqual(planner.handle(" ")?.body, "long")

        typeCharacters(";out", into: &planner)
        XCTAssertEqual(planner.handle(" ")?.body, "short")
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
        XCTAssertNotNil(planner.handle(" "))
    }

    func testDisqualifyingModifiersPreventExpansionAndResetBuffer() {
        var planner = planner(mode: .autoExpand)
        typeCharacters(";email", into: &planner)

        XCTAssertNil(planner.handle(" ", hasDisqualifyingModifiers: true))
        XCTAssertNil(planner.handle(" "))
        typeCharacters(";email", into: &planner)
        XCTAssertNotNil(planner.handle(" "))
    }

    private func planner(
        mode: MacClippySnippetExpansionMode
    ) -> MacClippySnippetExpansionPlanner {
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
