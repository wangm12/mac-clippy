import AppKit
import MacClippyPlatform

@MainActor
extension MacClippyDockController {
    func applyKeyAction(_ action: MacClippyDockKeyAction) -> Bool {
        switch action {
        case .consume:
            return true
        case .native:
            return false
        case .dismissModal, .enterSearch, .exitSearch, .closeDock, .showPreview, .hidePreview,
             .showDetails, .hideDetails, .editContent, .rename, .cancelDetailsEdit:
            applyNavigationAction(action)
        case .copy, .moveFocus, .extendRange, .paste:
            applyClipboardAction(action)
        case .appendSearch, .deleteSearchCharacter:
            applySearchAction(action)
        case .selectAll, .clearSelection, .deleteSelection, .pinSelection:
            applySelectionAction(action)
        case let .activateShortcut(number):
            model.activateShortcut(number, completion: { [weak self] in self?.hide() })
        }
        return true
    }

    private func applyNavigationAction(_ action: MacClippyDockKeyAction) {
        switch action {
        case .dismissModal, .enterSearch, .exitSearch, .closeDock:
            applyDockNavigationAction(action)
        case .showPreview, .hidePreview:
            applyPreviewNavigationAction(action)
        case .showDetails, .hideDetails, .editContent, .rename, .cancelDetailsEdit:
            applyDetailsNavigationAction(action)
        default: break
        }
    }

    private func applyDockNavigationAction(_ action: MacClippyDockKeyAction) {
        switch action {
        case .dismissModal: model.dismissModal()
        case .enterSearch: enterSearchMode()
        case .exitSearch: enterPickerMode()
        case .closeDock: hide()
        default: break
        }
    }

    private func applyPreviewNavigationAction(_ action: MacClippyDockKeyAction) {
        switch action {
        case .showPreview: showPreview()
        case .hidePreview: hidePreview()
        default: break
        }
    }

    private func applyDetailsNavigationAction(_ action: MacClippyDockKeyAction) {
        switch action {
        case .showDetails: showDetails()
        case .hideDetails: hideDetails()
        case .editContent: beginDetailsEditing(.content)
        case .rename: beginDetailsEditing(.name)
        case .cancelDetailsEdit: cancelDetailsEditing()
        default: break
        }
    }

    private func applyClipboardAction(_ action: MacClippyDockKeyAction) {
        switch action {
        case .copy: model.copyFocused()
        case let .moveFocus(direction): moveFocusedPreview(direction: direction)
        case let .extendRange(direction): model.extendRangeByStep(direction)
        case .paste: pasteFocusedSelection()
        default: break
        }
    }

    private func applySearchAction(_ action: MacClippyDockKeyAction) {
        switch action {
        case let .appendSearch(text):
            setSearchMode(true)
            model.appendSearchText(text)
        case .deleteSearchCharacter:
            model.deleteSearchCharacter()
        default: break
        }
    }

    private func applySelectionAction(_ action: MacClippyDockKeyAction) {
        switch action {
        case .selectAll: model.selectAllVisible()
        case .clearSelection: model.clearSelection()
        case .deleteSelection: model.deleteSelected()
        case .pinSelection: model.pinSelected()
        default: break
        }
    }

    private func pasteFocusedSelection() {
        if model.hasMultipleSelection {
            model.pasteSelectedAll(completion: { [weak self] in self?.hide() })
        } else {
            model.pasteFocused(completion: { [weak self] in self?.hide() })
        }
    }
}
