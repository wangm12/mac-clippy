import Foundation

public enum MacClippyDockFramePolicy {
    public static let minimumHeight: CGFloat = 220
    // Compact panel: 220pt cards, 10pt carousel padding, a 48pt header, 10pt
    // section spacing, and 22pt outer vertical padding.
    public static let preferredHeight: CGFloat = 340
    public static let selectionHeight: CGFloat = 340
    public static let maximumHeight: CGFloat = preferredHeight

    public static func frame(for screenFrame: CGRect, height: CGFloat) -> CGRect {
        let availableHeight = max(0, screenFrame.height)
        let boundedHeight = min(max(height, minimumHeight), maximumHeight)
        let resolvedHeight = min(boundedHeight, availableHeight)
        return CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: screenFrame.width,
            height: resolvedHeight
        )
    }

    public static func preferredHeight(hasMultipleSelection: Bool) -> CGFloat {
        hasMultipleSelection ? selectionHeight : preferredHeight
    }

    // Convenience for callers that want the correct content-state height
    // without hardcoding a number, so the policy stays the single source of
    // truth.
    public static func frame(for screenFrame: CGRect) -> CGRect {
        frame(for: screenFrame, hasMultipleSelection: false)
    }

    public static func frame(for screenFrame: CGRect, hasMultipleSelection: Bool) -> CGRect {
        frame(for: screenFrame, height: preferredHeight(hasMultipleSelection: hasMultipleSelection))
    }
}

public enum MacClippyDockLifecyclePolicy {
    public static func shouldDismissForKeyCode(_ keyCode: UInt16) -> Bool {
        keyCode == 53
    }

    public static func shouldDismissForOutsideClick(
        panelFrame: CGRect,
        clickLocation: CGPoint,
        ignoreUntil: Date,
        now: Date
    ) -> Bool {
        guard now >= ignoreUntil else { return false }
        return !panelFrame.contains(clickLocation)
    }
}
