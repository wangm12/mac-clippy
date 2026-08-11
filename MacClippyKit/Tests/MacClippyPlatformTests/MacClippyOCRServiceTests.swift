import Foundation
import XCTest

import MacClippyPlatform

final class MacClippyOCRServiceTests: XCTestCase {
    func testInvalidImageDataThrowsInvalidImage() async {
        do {
            _ = try await MacClippyOCRService().recognize(data: Data([0x01, 0x02, 0x03]))
            XCTFail("Expected invalid image error")
        } catch let error as MacClippyOCRError {
            XCTAssertEqual(error, .invalidImage)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOCRLayoutBuildsStableFullTextWithoutLeakingImplementationDetails() {
        let firstLine = MacClippyOCRTextLine(
            text: "git status",
            boundingBox: MacClippyOCRNormalizedRect(minX: 0.1, minY: 0.7, width: 0.4, height: 0.1),
            characters: [
                MacClippyOCRCharacter(text: "g", boundingBox: nil),
                MacClippyOCRCharacter(text: "i", boundingBox: nil),
                MacClippyOCRCharacter(text: "t", boundingBox: nil),
                MacClippyOCRCharacter(text: " ", boundingBox: nil),
                MacClippyOCRCharacter(text: "s", boundingBox: nil),
                MacClippyOCRCharacter(text: "t", boundingBox: nil),
                MacClippyOCRCharacter(text: "a", boundingBox: nil),
                MacClippyOCRCharacter(text: "t", boundingBox: nil),
                MacClippyOCRCharacter(text: "u", boundingBox: nil),
                MacClippyOCRCharacter(text: "s", boundingBox: nil)
            ]
        )
        let secondLine = MacClippyOCRTextLine(
            text: "✅ done",
            boundingBox: MacClippyOCRNormalizedRect(minX: 0.1, minY: 0.5, width: 0.4, height: 0.1),
            characters: [
                MacClippyOCRCharacter(text: "✅", boundingBox: nil),
                MacClippyOCRCharacter(text: " ", boundingBox: nil),
                MacClippyOCRCharacter(text: "d", boundingBox: nil),
                MacClippyOCRCharacter(text: "o", boundingBox: nil),
                MacClippyOCRCharacter(text: "n", boundingBox: nil),
                MacClippyOCRCharacter(text: "e", boundingBox: nil)
            ]
        )

        let result = MacClippyOCRResult(lines: [firstLine, secondLine])

        XCTAssertEqual(result.fullText, "git status\n✅ done")
        XCTAssertFalse(firstLine.hasCompleteCharacterGeometry)
        XCTAssertFalse(secondLine.hasCompleteCharacterGeometry)
    }

    func testOCRLayoutReportsCompleteCharacterGeometryOnlyWhenEveryCharacterHasABox() {
        let line = MacClippyOCRTextLine(
            text: "ab",
            boundingBox: MacClippyOCRNormalizedRect(minX: 0, minY: 0, width: 1, height: 1),
            characters: [
                MacClippyOCRCharacter(
                    text: "a",
                    boundingBox: MacClippyOCRNormalizedRect(minX: 0, minY: 0, width: 0.5, height: 1)
                ),
                MacClippyOCRCharacter(
                    text: "b",
                    boundingBox: MacClippyOCRNormalizedRect(minX: 0.5, minY: 0, width: 0.5, height: 1)
                )
            ]
        )

        XCTAssertTrue(line.hasCompleteCharacterGeometry)
    }
}
