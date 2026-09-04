import XCTest

@testable import MacClippyCore

final class MacClippyTextTransformPolicyTests: XCTestCase {
    func testTitleCaseMarkdownQuoteAndSortLines() {
        XCTAssertEqual(
            TextTransform.titleCase.apply(to: "hello WORLD from clippy"),
            "Hello World From Clippy"
        )
        XCTAssertEqual(
            TextTransform.markdownQuote.apply(to: "line1\nline2"),
            "> line1\n> line2"
        )
        XCTAssertEqual(
            TextTransform.sortLines.apply(to: "c\na\nb"),
            "a\nb\nc"
        )
    }

    func testTransformsComposeInDeclaredOrder() {
        XCTAssertEqual(
            MacClippyTextTransforms.apply([.trim, .titleCase, .markdownQuote], to: "  hello world  "),
            "> Hello World"
        )
    }

    func testShellFiltersAreNotOffered() {
        XCTAssertFalse(TextTransform.allCases.contains { $0.rawValue == "shell" })
    }
}
