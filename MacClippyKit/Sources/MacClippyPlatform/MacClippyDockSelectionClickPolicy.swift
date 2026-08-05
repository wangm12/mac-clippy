import AppKit

// Pure pointer-click decisions for multi-select. Keeping this policy separate
// from keyboard routing makes the Button path explicit without duplicating
// click semantics in the controller.
public enum MacClippyDockSelectionClickPolicy {
    public enum Action: Equatable {
        case focus
        case copy
        case toggle
        case extendRange
    }

    public static func decision(
        clickCount: Int,
        modifiers: NSEvent.ModifierFlags
    ) -> Action {
        // A double click is always a copy, regardless of modifiers.
        if clickCount >= 2 {
            return .copy
        }
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        if command {
            return .toggle
        }
        if shift {
            return .extendRange
        }
        return .focus
    }
}
