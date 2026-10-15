import AppKit
import MacClippyPlatform
import MacClippyCore

@MainActor
extension MacClippyDockController {
    func applyKeyAction(_ action: MacClippyDockKeyAction) -> Bool {
        switch action {
        case .consume:
            return true
        case .native:
            return false
        case .handOffSearchToInputMethod:
            enterSearchMode()
            return false
        case .dismissModal, .enterSearch, .focusResults, .exitSearch, .closeDock, .showPreview, .hidePreview,
             .showDetails, .retryDetails, .hideDetails, .editContent, .rename, .cancelDetailsEdit:
            applyNavigationAction(action)
        case .copy, .moveFocus, .extendRange, .paste(_):
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
        case .dismissModal, .enterSearch, .focusResults, .exitSearch, .closeDock:
            applyDockNavigationAction(action)
        case .showPreview, .hidePreview:
            applyPreviewNavigationAction(action)
        case .showDetails, .retryDetails, .hideDetails, .editContent, .rename, .cancelDetailsEdit:
            applyDetailsNavigationAction(action)
        default: break
        }
    }

    private func applyDockNavigationAction(_ action: MacClippyDockKeyAction) {
        switch action {
        case .dismissModal:
            if !model.isCreatingPinboard { model.dismissModal() }
        case .enterSearch: enterSearchMode()
        case .focusResults: focusResults()
        case .exitSearch:
            if MacClippyDockSearchEscapePolicy.clearsQueryFirst(model.query) {
                model.clearSearchQuery()
            } else if MacClippyDockSearchEscapePolicy.dismissesDockWhenQueryIsEmpty() {
                hide()
            } else if MacClippyDockSearchEscapePolicy.shouldChangeOverlayLevel() {
                enterPickerMode()
            } else {
                hide()
            }
        case .closeDock: hide()
        default: break
        }
    }

    private func applyPreviewNavigationAction(_ action: MacClippyDockKeyAction) {
        switch action {
        case .showPreview:
            if interactionMode == .details, let id = detailsTargetID {
                showPreview(for: .item(id))
            } else { showPreview() }
        case .hidePreview: hidePreview()
        default: break
        }
    }

    private func applyDetailsNavigationAction(_ action: MacClippyDockKeyAction) {
        switch action {
        case .showDetails: showFocusedDetails()
        case .retryDetails: refreshDetails()
        case .hideDetails: hideDetails()
        case .editContent: beginDetailsEditing(.content)
        case .rename: beginDetailsEditing(.name)
        case .cancelDetailsEdit: cancelDetailsEditing()
        default: break
        }
    }

    private func showFocusedDetails() {
        if interactionMode == .preview, case let .snippet(id)? = previewTarget {
            guard let snippet = model.snippets.first(where: { $0.id == id }) else { return }
            presentSnippetEditor(snippet: snippet)
        } else if interactionMode != .preview, model.selectedTab == .snippets {
            guard let snippet = model.focusedSnippet else { return }
            presentSnippetEditor(snippet: snippet)
        } else {
            showDetails(targetID: interactionMode == .preview ? previewTarget?.recordID : nil)
        }
    }

    private func applyClipboardAction(_ action: MacClippyDockKeyAction) {
        switch action {
        case .copy: copyDisplayedOrFocusedItem()
        case let .moveFocus(direction): moveFocusedPreview(direction: direction)
        case let .extendRange(direction): model.extendRangeByStep(direction)
        case let .paste(plain): pasteDisplayedOrFocusedItem(plain: plain)
        default: break
        }
    }

    private func copyDisplayedOrFocusedItem() {
        if interactionMode == .details, let id = detailsTargetID {
            guard details?.id == id else { return }
            model.copyRecord(id: id)
        } else if interactionMode == .preview, let target = previewTarget {
            model.copyTarget(target)
        } else { model.copyFocused() }
    }

    private func pasteDisplayedOrFocusedItem(plain: Bool) {
        if interactionMode == .details, let id = detailsTargetID {
            guard details?.id == id else { return }
            model.selectRecord(id: id, plain: plain, completion: { [weak self] in self?.hide() })
        } else if interactionMode == .preview, let target = previewTarget {
            model.pasteTarget(target, plain: plain, completion: { [weak self] in self?.hide() })
        } else { pasteFocusedSelection(plain: plain) }
    }

    private func applySearchAction(_ action: MacClippyDockKeyAction) {
        switch action {
        case let .appendSearch(text):
            model.appendSearchText(text)
            setSearchMode(true)
        case .deleteSearchCharacter:
            model.deleteSearchCharacter()
        default: break
        }
    }

    private func applySelectionAction(_ action: MacClippyDockKeyAction) {
        switch action {
        case .selectAll: model.selectAllVisible()
        case .clearSelection: model.clearSelection()
        case .deleteSelection: deleteDisplayedOrFocusedItem()
        case .pinSelection:
            if let id = displayedRecordID {
                guard dismissDisplayedRecordSurface() else { return }
                model.requestPinSelection(ids: [id])
            } else { model.requestPinSelection() }
        default: break
        }
    }

    private func deleteDisplayedOrFocusedItem() {
        if interactionMode == .preview, case let .snippet(id)? = previewTarget {
            hidePreview()
            model.deleteSnippet(id: id)
        } else if let id = displayedRecordID {
            guard dismissDisplayedRecordSurface() else { return }
            model.requestDeleteRecords(ids: [id])
        } else if model.selectedTab == .snippets, let snippet = model.focusedSnippet {
            model.deleteSnippet(id: snippet.id)
        } else { model.requestDeleteSelected() }
    }

    private var displayedRecordID: RecordID? {
        if interactionMode == .details { return detailsTargetID }
        if interactionMode == .preview, case let .item(id)? = previewTarget { return id }
        return nil
    }

    private func dismissDisplayedRecordSurface() -> Bool {
        if interactionMode == .details { return hideDetails() }
        hidePreview()
        return true
    }

    private func pasteFocusedSelection(plain: Bool) {
        guard model.selectionIsReady else { return }
        restorePasteTargetApplicationIfNeeded(
            leavingSearch: interactionMode == .search,
            isHiding: false
        )
        if model.hasMultipleSelection {
            model.pasteSelectedAll(completion: { [weak self] in self?.hide() })
        } else {
            model.pasteFocused(plain: plain, completion: { [weak self] in self?.hide() })
        }
    }
}
