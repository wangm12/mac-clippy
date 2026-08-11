import AppKit

import MacClippyCore
import MacClippyPlatform

extension MacClippyDockView {
    func focusCard() {
        isSearchFocused = false
        onEnterPickerMode()
    }

    func handleCardClick(
        clickCount: Int,
        modifiers: NSEvent.ModifierFlags,
        focus: () -> Void,
        selection: ((MacClippyDockSelectionClickPolicy.Action) -> Void)? = nil
    ) {
        focusCard()
        let action = MacClippyDockSelectionClickPolicy.decision(
            clickCount: clickCount,
            modifiers: modifiers
        )
        switch action {
        case .copy:
            focus()
            model.copyFocused(
                plain: false,
                completion: {
                    onCopyToast(MacClippyDockActionFeedback.copied(plain: false).title)
                    onClose()
                }
            )
        case .focus:
            focus()
        case .toggle, .extendRange:
            if let selection {
                selection(action)
            } else {
                focus()
            }
        }
    }

    func currentModifierFlags() -> NSEvent.ModifierFlags {
        NSEvent.modifierFlags.intersection([.command, .shift, .option, .control])
    }
}
