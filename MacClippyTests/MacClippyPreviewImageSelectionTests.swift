import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyPreviewImageSelectionTests: XCTestCase {
    private func line(_ text: String) -> MacClippyOCRTextLine {
        MacClippyOCRTextLine(
            text: text,
            boundingBox: MacClippyOCRNormalizedRect(minX: 0, minY: 0, width: 1, height: 1),
            characters: text.map { MacClippyOCRCharacter(text: String($0), boundingBox: nil) }
        )
    }

    func testAspectFitCentersLandscapeImageInsideLetterboxBounds() {
        let rect = MacClippyPreviewImageGeometry.aspectFitRect(
            imageSize: CGSize(width: 1_600, height: 800),
            in: NSRect(x: 0, y: 0, width: 400, height: 300)
        )

        XCTAssertEqual(rect, NSRect(x: 0, y: 50, width: 400, height: 200))
    }

    func testAspectFitCentersPortraitImageInsideLetterboxBounds() {
        let rect = MacClippyPreviewImageGeometry.aspectFitRect(
            imageSize: CGSize(width: 800, height: 1_600),
            in: NSRect(x: 10, y: 20, width: 400, height: 300)
        )

        XCTAssertEqual(rect, NSRect(x: 135, y: 20, width: 150, height: 300))
    }

    func testVisionLowerLeftCoordinatesMapToFlippedAppKitImageRect() {
        let imageRect = NSRect(x: 10, y: 20, width: 200, height: 100)
        let normalized = MacClippyOCRNormalizedRect(
            minX: 0.25,
            minY: 0.10,
            width: 0.50,
            height: 0.20
        )

        let mapped = MacClippyPreviewImageGeometry.map(normalized, into: imageRect)

        XCTAssertEqual(mapped, NSRect(x: 60, y: 90, width: 100, height: 20))
    }

    func testEmptyBoundsProduceNoSelectableImageRect() {
        XCTAssertEqual(
            MacClippyPreviewImageGeometry.aspectFitRect(
                imageSize: CGSize(width: 100, height: 100),
                in: .zero
            ),
            .zero
        )
    }

    @MainActor
    func testPreviewSelectionSurfacesAcceptTheFirstMouse() {
        let selectionView = MacClippyOCRSelectionView()
        let hostingView = MacClippyPreviewHostingView(
            rootView: MacClippyDockPreviewView(content: .loading)
        )

        XCTAssertTrue(selectionView.acceptsFirstMouse(for: nil))
        XCTAssertTrue(hostingView.acceptsFirstMouse(for: nil))
    }

    func testSelectionPolicySupportsCrossLineAndReverseSelection() {
        let result = MacClippyOCRResult(lines: [line("copy me"), line("next line")])

        XCTAssertEqual(
            MacClippyOCRSelectionPolicy.selectedText(
                in: result,
                anchor: MacClippyOCRTextPosition(line: 0, offset: 5),
                active: MacClippyOCRTextPosition(line: 1, offset: 4)
            ),
            "me\nnext"
        )
        XCTAssertEqual(
            MacClippyOCRSelectionPolicy.selectedText(
                in: result,
                anchor: MacClippyOCRTextPosition(line: 1, offset: 4),
                active: MacClippyOCRTextPosition(line: 0, offset: 5)
            ),
            "me\nnext"
        )
    }

    func testSelectionPolicyClampsStaleOffsetsAndPreservesEmojiClusters() {
        let result = MacClippyOCRResult(lines: [line("A✅B")])

        XCTAssertEqual(
            MacClippyOCRSelectionPolicy.selectedText(
                in: result,
                anchor: MacClippyOCRTextPosition(line: 0, offset: -10),
                active: MacClippyOCRTextPosition(line: 0, offset: 100)
            ),
            "A✅B"
        )
    }

    func testSelectionAppearanceAvoidsSolidAccentBlocks() {
        let characterRect = NSRect(x: 10, y: 20, width: 100, height: 20)
        let highlightedCharacter = MacClippyOCRSelectionAppearance.characterHighlightRect(characterRect)

        XCTAssertLessThan(
            MacClippyOCRSelectionAppearance.fallbackLineFillOpacity,
            MacClippyOCRSelectionAppearance.characterFillOpacity
        )
        XCTAssertLessThan(MacClippyOCRSelectionAppearance.characterFillOpacity, 0.16)
        XCTAssertGreaterThan(
            MacClippyOCRSelectionAppearance.characterStrokeOpacity,
            MacClippyOCRSelectionAppearance.characterFillOpacity
        )
        XCTAssertLessThan(highlightedCharacter.width, characterRect.width)
        XCTAssertLessThan(highlightedCharacter.height, characterRect.height)
    }

    func testPreviewIdentityUsesRecordIDInsteadOfPayloadBytes() {
        let id = RecordID.generate()
        let first = MacClippyDockPreviewContent.image(id: id, data: Data(repeating: 0, count: 4))
        let second = MacClippyDockPreviewContent.image(id: id, data: Data(repeating: 1, count: 4))

        XCTAssertEqual(
            first.identity,
            second.identity
        )
    }

    func testPreviewCopyUsesSelectionBeforeFullOCRText() {
        XCTAssertEqual(
            MacClippyDockPreviewTextCopyPolicy.textToCopy(
                selectedText: "selected",
                fullText: "full OCR text"
            ),
            "selected"
        )
        XCTAssertTrue(MacClippyDockPreviewTextCopyPolicy.isSelection(selectedText: "selected"))
    }

    func testPreviewCopyFallsBackToFullOCRTextWhenNoSelectionExists() {
        XCTAssertEqual(
            MacClippyDockPreviewTextCopyPolicy.textToCopy(
                selectedText: nil,
                fullText: "full OCR text"
            ),
            "full OCR text"
        )
        XCTAssertFalse(MacClippyDockPreviewTextCopyPolicy.isSelection(selectedText: nil))
    }
}
