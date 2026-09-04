import AppKit
import MacClippyPlatform

extension MacClippyOCRSelectionView {
    func drawSearchHits(
        result: MacClippyOCRResult,
        imageRect: NSRect,
        terms: [String]
    ) {
        let boxes = MacClippyOCRSearchHighlightPolicy.highlightedBoxes(in: result, terms: terms)
        for box in boxes {
            let mapped = MacClippyPreviewImageGeometry.map(box, into: imageRect)
            guard mapped.width > 0, mapped.height > 0 else { continue }
            let highlightRect = MacClippyOCRSelectionAppearance.characterHighlightRect(mapped)
            let path = selectionPath(for: highlightRect, radius: 2.5)
            MacClippyOCRSelectionAppearance.searchHitColor
                .withAlphaComponent(MacClippyOCRSelectionAppearance.searchHitFillOpacity)
                .setFill()
            path.fill()
            MacClippyOCRSelectionAppearance.searchHitColor
                .withAlphaComponent(MacClippyOCRSelectionAppearance.searchHitStrokeOpacity)
                .setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    func drawSelection(
        _ selection: Selection,
        result: MacClippyOCRResult,
        layout: MacClippyOCRSelectionLayout
    ) {
        let (start, end) = selection.ordered
        for lineIndex in start.line...end.line {
            guard result.lines.indices.contains(lineIndex) else { continue }
            let line = result.lines[lineIndex]
            let lowerBound = min(
                max(lineIndex == start.line ? start.offset : 0, 0),
                line.characters.count
            )
            let upperBound = min(
                max(lineIndex == end.line ? end.offset : line.characters.count, 0),
                line.characters.count
            )
            guard lowerBound < upperBound else { continue }

            if line.hasCompleteCharacterGeometry {
                drawCharacterSelection(
                    layout.characterRects[lineIndex][lowerBound..<upperBound]
                )
            } else {
                drawFallbackLineSelection(layout.lineRects[lineIndex])
            }
        }
    }

    func drawCharacterSelection(
        _ characterRects: ArraySlice<NSRect?>
    ) {
        var selectionRect: NSRect?
        for characterRect in characterRects {
            guard let characterRect else { continue }
            guard characterRect.width > 0, characterRect.height > 0 else { continue }
            selectionRect = selectionRect.map { $0.union(characterRect) } ?? characterRect
        }
        guard let selectionRect else { return }
        let highlightRect = MacClippyOCRSelectionAppearance.characterHighlightRect(selectionRect)
        drawSelectionHighlight(in: highlightRect, radius: 2.5)
    }

    func drawSelectionHighlight(in rect: NSRect, radius: CGFloat) {
        let path = selectionPath(for: rect, radius: radius)
        MacClippyOCRSelectionAppearance.selectionColor
            .withAlphaComponent(MacClippyOCRSelectionAppearance.characterFillOpacity)
            .setFill()
        path.fill()
        MacClippyOCRSelectionAppearance.selectionColor
            .withAlphaComponent(MacClippyOCRSelectionAppearance.characterStrokeOpacity)
            .setStroke()
        path.lineWidth = 1.25
        path.stroke()
    }

    func drawFallbackLineSelection(
        _ lineRect: NSRect
    ) {
        guard lineRect.width > 0, lineRect.height > 0 else { return }
        let highlightRect = MacClippyOCRSelectionAppearance.fallbackLineHighlightRect(lineRect)
        let path = selectionPath(for: highlightRect, radius: 3)
        MacClippyOCRSelectionAppearance.selectionColor
            .withAlphaComponent(MacClippyOCRSelectionAppearance.fallbackLineFillOpacity)
            .setFill()
        path.fill()
        MacClippyOCRSelectionAppearance.selectionColor
            .withAlphaComponent(MacClippyOCRSelectionAppearance.fallbackLineStrokeOpacity)
            .setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    func selectionPath(for rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let cornerRadius = min(radius, rect.height / 2)
        return NSBezierPath(
            roundedRect: rect,
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
    }
}
