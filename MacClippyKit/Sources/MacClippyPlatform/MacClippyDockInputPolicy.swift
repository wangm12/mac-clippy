import AppKit
import MacClippyCore

public enum MacClippyDockInteractionMode: Equatable {
    case picker
    case search
    case preview
    case details
    case modal
}

public enum MacClippyDockKeyEvent: Equatable {
    case keyDown(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags,
        isRepeat: Bool
    )
    case keyUp(keyCode: UInt16, modifiers: NSEvent.ModifierFlags)
}

public enum MacClippyDockKeyAction: Equatable {
    case consume
    case native
    case dismissModal
    case enterSearch
    case exitSearch
    case closeDock
    case showPreview
    case hidePreview
    case showDetails
    case hideDetails
    case editContent
    case rename
    case cancelDetailsEdit
    case copy
    case moveFocus(MacClippyDockSelectionDirection)
    case extendRange(MacClippyDockSelectionDirection)
    case paste(plain: Bool)
    case appendSearch(String)
    case deleteSearchCharacter
    case selectAll
    case clearSelection
    case deleteSelection
    case pinSelection
    case activateShortcut(Int)
}

private struct MacClippyDockKeyDownContext {
    let keyCode: UInt16
    let characters: String?
    let modifiers: NSEvent.ModifierFlags
    let isRepeat: Bool
    let mode: MacClippyDockInteractionMode
    let hasCardFocus: Bool
    let hasMultipleSelection: Bool
    let detailsEditing: Bool
    let hasTextSelection: Bool
    let isLoading: Bool
    let alwaysPastePlainText: Bool
}

public enum MacClippyDockKeyRouterPolicy {
    private static let commandModifiers: NSEvent.ModifierFlags = [.command, .option, .control]

    public static func isCommandCopy(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let deviceIndependentModifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        return keyCode == 8 && deviceIndependentModifiers == [.command]
    }

    public static func action(
        for event: MacClippyDockKeyEvent,
        mode: MacClippyDockInteractionMode,
        hasCardFocus: Bool,
        hasMultipleSelection: Bool,
        detailsEditing: Bool = false,
        hasTextSelection: Bool = false,
        isLoading: Bool = false,
        alwaysPastePlainText: Bool = false
    ) -> MacClippyDockKeyAction {
        switch event {
        case let .keyUp(keyCode, _):
            return keyUpAction(keyCode: keyCode, mode: mode, detailsEditing: detailsEditing)

        case let .keyDown(keyCode, characters, modifiers, isRepeat):
            return keyDownAction(MacClippyDockKeyDownContext(
                keyCode: keyCode,
                characters: characters,
                modifiers: modifiers,
                isRepeat: isRepeat,
                mode: mode,
                hasCardFocus: hasCardFocus,
                hasMultipleSelection: hasMultipleSelection,
                detailsEditing: detailsEditing,
                hasTextSelection: hasTextSelection,
                isLoading: isLoading,
                alwaysPastePlainText: alwaysPastePlainText
            ))
        }
    }
}

private extension MacClippyDockKeyRouterPolicy {
    private static func keyUpAction(
        keyCode: UInt16,
        mode: MacClippyDockInteractionMode,
        detailsEditing: Bool
    ) -> MacClippyDockKeyAction {
        if mode == .modal || (mode == .details && detailsEditing) {
            return .native
        }
        if mode == .search, keyCode != 53 {
            return .native
        }
        return .consume
    }

    private static func keyDownAction(_ context: MacClippyDockKeyDownContext) -> MacClippyDockKeyAction {
        if let preflightAction = preflightKeyDownAction(context) {
            return preflightAction
        }
        if context.keyCode == 53 {
            return escapeAction(
                mode: context.mode,
                detailsEditing: context.detailsEditing,
                hasMultipleSelection: context.hasMultipleSelection
            )
        }
        guard context.mode != .search else { return .native }

        if let contentAction = contentKeyDownAction(context) {
            return contentAction
        }
        if context.mode == .preview {
            return .consume
        }
        if context.mode == .details {
            return detailsAction(context)
        }
        if let searchAction = searchInputAction(context) {
            return searchAction
        }
        return shortcutAction(keyCode: context.keyCode, modifiers: context.modifiers) ?? .native
    }

    private static func preflightKeyDownAction(
        _ context: MacClippyDockKeyDownContext
    ) -> MacClippyDockKeyAction? {
        if context.mode == .modal {
            return context.keyCode == 53 ? .dismissModal : .native
        }
        if context.mode == .details, context.detailsEditing {
            return context.keyCode == 53 ? .cancelDetailsEdit : .native
        }
        if context.keyCode == 9,
           context.modifiers.contains([.command, .option]),
           context.modifiers.isDisjoint(with: [.control, .shift]) {
            return context.mode == .details ? .hideDetails : .showDetails
        }
        if context.keyCode == 40,
           context.modifiers.contains(.command),
           context.modifiers.isDisjoint(with: [.option, .control]) {
            return .enterSearch
        }
        return nil
    }

    private static func contentKeyDownAction(
        _ context: MacClippyDockKeyDownContext
    ) -> MacClippyDockKeyAction? {
        // Preserve the standard macOS copy shortcut on both Preview and
        // non-editing Details. The picker owns the event monitor, so this
        // must be routed explicitly instead of being swallowed below.
        if isCommandCopy(keyCode: context.keyCode, modifiers: context.modifiers), context.hasCardFocus {
            return context.hasTextSelection ? .native : .copy
        }
        if let selectionAction = selectionAction(context) {
            return selectionAction
        }
        if let spaceAction = spaceAction(context) {
            return spaceAction
        }
        if let movementAction = movementAction(context) {
            return movementAction
        }
        if let pasteAction = pasteAction(context) {
            return pasteAction
        }
        return nil
    }

    private static func spaceAction(
        _ context: MacClippyDockKeyDownContext
    ) -> MacClippyDockKeyAction? {
        guard context.keyCode == 49,
              context.modifiers.isDisjoint(with: commandModifiers) else {
            return nil
        }
        // Space is a toggle, not a repeatable navigation key. Without this
        // guard a held Space opens Preview and its repeated keyDown immediately closes it again.
        guard !context.isRepeat else { return .consume }
        if context.mode == .preview {
            return .hidePreview
        }
        return context.hasCardFocus || context.isLoading ? .showPreview : .consume
    }

    private static func movementAction(
        _ context: MacClippyDockKeyDownContext
    ) -> MacClippyDockKeyAction? {
        guard context.keyCode == 123 || context.keyCode == 124 else { return nil }
        guard context.modifiers.isDisjoint(with: [.option, .control]) else { return .native }
        if context.modifiers.contains(.shift) {
            return .extendRange(context.keyCode == 123 ? .left : .right)
        }
        guard !context.modifiers.contains(.command) else { return .native }
        guard context.hasCardFocus else { return .consume }
        return .moveFocus(context.keyCode == 123 ? .left : .right)
    }

    private static func pasteAction(
        _ context: MacClippyDockKeyDownContext
    ) -> MacClippyDockKeyAction? {
        guard context.keyCode == 36 || context.keyCode == 76 else { return nil }
        guard context.modifiers.isDisjoint(with: commandModifiers) else { return .native }
        guard !context.isRepeat else { return .consume }
        guard context.hasCardFocus else { return .consume }
        return .paste(
            plain: MacClippyPastePlainTextPolicy.shouldPastePlain(
                alwaysPlain: context.alwaysPastePlainText,
                shiftHeld: context.modifiers.contains(.shift)
            )
        )
    }

    private static func detailsAction(
        _ context: MacClippyDockKeyDownContext
    ) -> MacClippyDockKeyAction {
        if context.modifiers == [.command], context.keyCode == 14 {
            return .editContent
        }
        if context.modifiers == [.command], context.keyCode == 15 {
            return .rename
        }
        return .consume
    }

    private static func searchInputAction(
        _ context: MacClippyDockKeyDownContext
    ) -> MacClippyDockKeyAction? {
        guard context.modifiers.isDisjoint(with: commandModifiers) else { return nil }
        if context.keyCode == 51 {
            return .deleteSearchCharacter
        }
        if let characters = context.characters,
           !characters.isEmpty,
           characters.rangeOfCharacter(from: .controlCharacters) == nil {
            return .appendSearch(characters)
        }
        return nil
    }

    private static func selectionAction(
        _ context: MacClippyDockKeyDownContext
    ) -> MacClippyDockKeyAction? {
        guard context.modifiers.isDisjoint(with: [.option, .control]) else { return nil }
        let command = context.modifiers.contains(.command)
        let shift = context.modifiers.contains(.shift)

        if command, !shift, context.keyCode == 0 {
            return .selectAll
        }
        // Cmd+Delete should remove the focused card even when the user has
        // not created a multi-selection. The model keeps the existing
        // single-card fallback, while multi-selection still routes through
        // the same batch delete action.
        let isDeleteKey = context.keyCode == 51 || context.keyCode == 117
        if command, !shift, isDeleteKey, context.hasCardFocus || context.hasMultipleSelection {
            return .deleteSelection
        }
        if command, !shift, context.keyCode == 35, context.hasMultipleSelection {
            return .pinSelection
        }
        return nil
    }

    private static func escapeAction(
        mode: MacClippyDockInteractionMode,
        detailsEditing: Bool,
        hasMultipleSelection: Bool
    ) -> MacClippyDockKeyAction {
        if mode == .search {
            return .exitSearch
        }
        if mode == .preview {
            return .hidePreview
        }
        if mode == .details {
            return detailsEditing ? .cancelDetailsEdit : .hideDetails
        }
        return hasMultipleSelection ? .clearSelection : .closeDock
    }

    private static func shortcutAction(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> MacClippyDockKeyAction? {
        guard modifiers.contains(.command),
              modifiers.isDisjoint(with: [.option, .control, .shift]) else {
            return nil
        }
        let numbers: [UInt16: Int] = [
            18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
            22: 6, 26: 7, 28: 8, 25: 9
        ]
        return numbers[keyCode].map(MacClippyDockKeyAction.activateShortcut)
    }
}
