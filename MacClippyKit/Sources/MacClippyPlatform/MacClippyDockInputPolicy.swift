import AppKit

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
    case moveFocus(MacClippyDockSelectionDirection)
    case extendRange(MacClippyDockSelectionDirection)
    case paste
    case appendSearch(String)
    case deleteSearchCharacter
    case selectAll
    case clearSelection
    case deleteSelection
    case pinSelection
    case activateShortcut(Int)
}

public enum MacClippyDockKeyRouterPolicy {
    private static let commandModifiers: NSEvent.ModifierFlags = [.command, .option, .control]

    public static func action(
        for event: MacClippyDockKeyEvent,
        mode: MacClippyDockInteractionMode,
        hasCardFocus: Bool,
        hasMultipleSelection: Bool,
        detailsEditing: Bool = false,
        isLoading: Bool = false
    ) -> MacClippyDockKeyAction {
        switch event {
        case let .keyUp(keyCode, _):
            if mode == .modal {
                return .native
            }
            if mode == .details, detailsEditing {
                return .native
            }
            if mode == .search, keyCode != 53 {
                return .native
            }
            return .consume

        case let .keyDown(keyCode, characters, modifiers, isRepeat):
            if mode == .modal {
                return keyCode == 53 ? .dismissModal : .native
            }
            if keyCode == 9,
               modifiers.contains([.command, .option]),
               modifiers.intersection([.control, .shift]).isEmpty {
                return mode == .details ? .hideDetails : .showDetails
            }

            if keyCode == 40,
               modifiers.contains(.command),
               modifiers.intersection([.option, .control]).isEmpty {
                return .enterSearch
            }

            if keyCode == 53 {
                if mode == .search {
                    return .exitSearch
                }
                if mode == .preview {
                    return .hidePreview
                }
                if mode == .details {
                    return detailsEditing ? .cancelDetailsEdit : .hideDetails
                }
                if hasMultipleSelection {
                    return .clearSelection
                }
                return .closeDock
            }

            guard mode != .search else { return .native }

            if mode == .details, detailsEditing {
                return .native
            }

            if let selectionAction = selectionAction(
                keyCode: keyCode,
                modifiers: modifiers,
                hasMultipleSelection: hasMultipleSelection
            ) {
                return selectionAction
            }

            if keyCode == 49,
               modifiers.intersection(commandModifiers).isEmpty {
                // Space is a toggle, not a repeatable navigation key. Without
                // this guard a held Space opens Preview and its repeated
                // keyDown immediately closes it again.
                guard !isRepeat else { return .consume }
                if mode == .preview {
                    return .hidePreview
                }
                return hasCardFocus || isLoading ? .showPreview : .consume
            }

            if keyCode == 123 || keyCode == 124 {
                guard modifiers.intersection([.option, .control]).isEmpty else { return .native }
                if modifiers.contains(.shift) {
                    return .extendRange(keyCode == 123 ? .left : .right)
                }
                guard !modifiers.contains(.command) else { return .native }
                guard hasCardFocus else { return .consume }
                return .moveFocus(keyCode == 123 ? .left : .right)
            }

            if keyCode == 36 || keyCode == 76 {
                guard modifiers.intersection(commandModifiers).isEmpty else { return .native }
                guard !isRepeat else { return .consume }
                return hasCardFocus ? .paste : .consume
            }

            if mode == .preview {
                return .consume
            }

            if mode == .details {
                if detailsEditing, keyCode == 53 {
                    return .cancelDetailsEdit
                }
                if detailsEditing {
                    return .native
                }
                if modifiers == [.command], keyCode == 14 {
                    return .editContent
                }
                if modifiers == [.command], keyCode == 15 {
                    return .rename
                }
                return .consume
            }

            if modifiers.intersection(commandModifiers).isEmpty {
                if keyCode == 51 {
                    return .deleteSearchCharacter
                }
                if let characters,
                   !characters.isEmpty,
                   characters.rangeOfCharacter(from: .controlCharacters) == nil {
                    return .appendSearch(characters)
                }
            }

            return shortcutAction(keyCode: keyCode, modifiers: modifiers) ?? .native
        }
    }

    private static func selectionAction(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        hasMultipleSelection: Bool
    ) -> MacClippyDockKeyAction? {
        guard modifiers.intersection([.option, .control]).isEmpty else { return nil }
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)

        if command, !shift, keyCode == 0 {
            return .selectAll
        }
        if command, !shift, (keyCode == 51 || keyCode == 117), hasMultipleSelection {
            return .deleteSelection
        }
        if command, !shift, keyCode == 35, hasMultipleSelection {
            return .pinSelection
        }
        return nil
    }

    private static func shortcutAction(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> MacClippyDockKeyAction? {
        guard modifiers.contains(.command),
              modifiers.intersection([.option, .control, .shift]).isEmpty else {
            return nil
        }
        let numbers: [UInt16: Int] = [
            18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
            22: 6, 26: 7, 28: 8, 25: 9
        ]
        return numbers[keyCode].map(MacClippyDockKeyAction.activateShortcut)
    }
}
