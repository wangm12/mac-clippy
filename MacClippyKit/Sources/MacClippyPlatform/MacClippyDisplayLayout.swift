import Foundation

public enum MacClippyDisplayLayout {
    public static func screenRect(
        containing point: CGPoint,
        from displayRects: [CGRect]
    ) -> CGRect? {
        ordered(displayRects).first { $0.contains(point) }
    }

    public static func screenRect(
        containing point: CGPoint,
        from displayRects: [CGRect],
        fallback: CGRect?
    ) -> CGRect? {
        let orderedRects = ordered(displayRects)
        if let containing = orderedRects.first(where: { $0.contains(point) }) {
            return containing
        }
        if let fallback,
           let matchingFallback = orderedRects.first(where: { $0 == fallback }) {
            return matchingFallback
        }
        return orderedRects.first
    }

    public static func clampedPreviewFrame(
        _ frame: CGRect,
        within visibleFrame: CGRect,
        above dockFrame: CGRect,
        spacing: CGFloat = 12
    ) -> CGRect? {
        guard visibleFrame.width > 0, visibleFrame.height > 0, frame.width > 0, frame.height > 0 else {
            return nil
        }

        let minimumY = max(visibleFrame.minY, dockFrame.maxY + spacing)
        let availableHeight = visibleFrame.maxY - minimumY
        guard availableHeight > 0 else { return nil }

        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, availableHeight)
        let x = min(
            max(frame.midX - width / 2, visibleFrame.minX),
            visibleFrame.maxX - width
        )
        let y = min(
            max(frame.minY, minimumY),
            visibleFrame.maxY - height
        )
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func ordered(_ displayRects: [CGRect]) -> [CGRect] {
        displayRects.sorted {
            if $0.minX != $1.minX { return $0.minX < $1.minX }
            if $0.minY != $1.minY { return $0.minY < $1.minY }
            if $0.width != $1.width { return $0.width < $1.width }
            if $0.height != $1.height { return $0.height < $1.height }
            return false
        }
    }
}
