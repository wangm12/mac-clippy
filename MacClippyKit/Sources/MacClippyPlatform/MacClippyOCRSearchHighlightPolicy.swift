import Foundation

import MacClippyCore

/// Maps search terms onto stored OCR layout boxes so preview can highlight
/// hits without changing the user's selection overlay.
public enum MacClippyOCRSearchHighlightPolicy {
    public static func highlightedBoxes(
        in result: MacClippyOCRResult,
        terms: [String]
    ) -> [MacClippyOCRNormalizedRect] {
        guard !terms.isEmpty else { return [] }

        var boxes: [MacClippyOCRNormalizedRect] = []
        for line in result.lines {
            let ranges = MacClippySearchQuery.highlightedRanges(in: line.text, queryTerms: terms)
            guard !ranges.isEmpty else { continue }
            if line.hasCompleteCharacterGeometry {
                for range in ranges {
                    let start = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
                    let end = line.text.distance(from: line.text.startIndex, to: range.upperBound)
                    guard start < end, end <= line.characters.count else {
                        boxes.append(line.boundingBox)
                        continue
                    }
                    let characterBoxes = line.characters[start..<end].compactMap(\.boundingBox)
                    if let union = union(characterBoxes) {
                        boxes.append(union)
                    }
                }
            } else {
                boxes.append(line.boundingBox)
            }
        }
        return boxes
    }

    private static func union(
        _ boxes: [MacClippyOCRNormalizedRect]
    ) -> MacClippyOCRNormalizedRect? {
        guard let first = boxes.first else { return nil }
        var minX = first.minX
        var minY = first.minY
        var maxX = first.minX + first.width
        var maxY = first.minY + first.height
        for box in boxes.dropFirst() {
            minX = min(minX, box.minX)
            minY = min(minY, box.minY)
            maxX = max(maxX, box.minX + box.width)
            maxY = max(maxY, box.minY + box.height)
        }
        return MacClippyOCRNormalizedRect(
            minX: minX,
            minY: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }
}
