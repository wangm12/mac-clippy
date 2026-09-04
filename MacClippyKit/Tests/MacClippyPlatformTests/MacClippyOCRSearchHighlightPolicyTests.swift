import XCTest

@testable import MacClippyPlatform

final class MacClippyOCRSearchHighlightPolicyTests: XCTestCase {
    func testMissingCharacterGeometryFallsBackToTheLineBox() {
        let lineBox = MacClippyOCRNormalizedRect(minX: 0.1, minY: 0.2, width: 0.8, height: 0.1)
        let result = MacClippyOCRResult(lines: [
            MacClippyOCRTextLine(
                text: "invoice 42",
                boundingBox: lineBox,
                characters: []
            )
        ])

        XCTAssertEqual(
            MacClippyOCRSearchHighlightPolicy.highlightedBoxes(in: result, terms: ["invoice"]),
            [lineBox]
        )
        XCTAssertEqual(
            MacClippyOCRSearchHighlightPolicy.highlightedBoxes(in: result, terms: []),
            []
        )
        XCTAssertEqual(
            MacClippyOCRSearchHighlightPolicy.highlightedBoxes(in: result, terms: ["missing"]),
            []
        )
    }

    func testCharacterBoxesUnionAroundTheMatchingRun() {
        let characters = "PASS".enumerated().map { index, character in
            MacClippyOCRCharacter(
                text: String(character),
                boundingBox: MacClippyOCRNormalizedRect(
                    minX: Double(index) * 0.25,
                    minY: 0.5,
                    width: 0.25,
                    height: 0.25
                )
            )
        }
        let result = MacClippyOCRResult(lines: [
            MacClippyOCRTextLine(
                text: "PASS",
                boundingBox: MacClippyOCRNormalizedRect(minX: 0, minY: 0.5, width: 1, height: 0.25),
                characters: characters
            )
        ])

        XCTAssertEqual(
            MacClippyOCRSearchHighlightPolicy.highlightedBoxes(in: result, terms: ["AS"]),
            [MacClippyOCRNormalizedRect(minX: 0.25, minY: 0.5, width: 0.5, height: 0.25)]
        )
    }
}
