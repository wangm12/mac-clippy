import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import SwiftUI

extension MacClippyDockView {
    func updateOverlaySearchFocus(presented: Bool) {
        overlayFocusGeneration &+= 1
        let generation = overlayFocusGeneration
        if presented {
            if overlaySearchSessionGeneration != model.sessionGeneration
                || (pendingSearchFocusReset != nil && pendingSearchFocusReset != model.searchFocusReset) {
                shouldRestoreSearchFocus = false
            }
            shouldRestoreSearchFocus = shouldRestoreSearchFocus || isSearchFocused || model.searchFocusIsRequested
            overlaySearchSessionGeneration = model.sessionGeneration
            pendingSearchFocusReset = nil
            // Release the native editor before either overlay asks for focus.
            isSearchFocused = false
            onSearchModeChange(false)
            onModalPresentationChange(true)
            overlaySearchFocusReset = model.searchFocusReset
            return
        }
        // Reject an old close before it can change the current surface mode.
        guard overlaySearchSessionGeneration == model.sessionGeneration,
              overlaySearchFocusReset == model.searchFocusReset else {
            shouldRestoreSearchFocus = false
            pendingSearchFocusReset = nil
            return
        }
        onModalPresentationChange(false)
        guard shouldRestoreSearchFocus, let session = overlaySearchSessionGeneration else { return }
        let reset = model.searchFocusReset
        pendingSearchFocusReset = reset
        DispatchQueue.main.async {
            guard overlayFocusGeneration == generation, model.modal == nil,
                  !model.isFilterPopoverPresented else { return }
            guard model.sessionGeneration == session, model.searchFocusReset == reset else {
                shouldRestoreSearchFocus = false
                pendingSearchFocusReset = nil
                return
            }
            onSearchModeChange(true)
            isSearchFocused = true
            shouldRestoreSearchFocus = false
            pendingSearchFocusReset = nil
        }
    }

    func updateModalAccessibilityFocus(presented: Bool) {
        modalFocusGeneration &+= 1
        let generation = modalFocusGeneration
        modalAccessibilityFocused = false
        guard presented else { return }
        DispatchQueue.main.async {
            guard modalFocusGeneration == generation, model.modal != nil else { return }
            modalAccessibilityFocused = true
        }
    }

    @ViewBuilder
    var modalOverlay: some View {
        if let modal = model.modal {
            ZStack {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if case .confirmDeleteCategory = modal {
                            model.dismissModal()
                        }
                    }
                switch modal {
                case .confirmDeleteItems(let ids, let includesPinned, let token):
                    MacClippyDeleteItemsConfirmation(count: ids.count, includesPinned: includesPinned) {
                        model.dismissModal()
                        model.deleteSelected(confirmedIDs: ids)
                    } onCancel: {
                        model.dismissModal()
                    }
                    .id(token)
                case .choosePinboard(let ids, let token):
                    MacClippyPinboardPicker(boards: model.pinboards) { boardID in
                        model.dismissModal()
                        model.pinSelected(to: boardID, ids: ids)
                    } onCancel: {
                        model.dismissModal()
                    }
                    .id(token)
                case .createCategory(let token):
                    MacClippyCreateCategoryEditor { name, color, completion in
                        model.createPinboard(name: name, color: color, modalToken: token) { succeeded in
                            completion(succeeded)
                        }
                    } onCancel: {
                        guard model.modal == .createCategory(token: token), !model.isCreatingPinboard else { return }
                        model.dismissModal()
                    }
                    .id(token)
                case .renameItem(let recordID, let initialName, let token):
                    MacClippyRenameItemEditor(initialName: initialName) { result in
                        if case .save(let name) = result {
                            model.renameItem(id: recordID, name: name)
                        }
                        model.dismissModal()
                    } onCancel: {
                        model.dismissModal()
                    }
                    .id(token)
                case .renameCategory(let pinboardID, let token):
                    Group {
                        if let pinboard = model.pinboards.first(where: { $0.id == pinboardID }) {
                            MacClippyRenameCategoryEditor(initialName: pinboard.name) { name in
                                model.renamePinboard(pinboard, to: name)
                                model.dismissModal()
                            } onCancel: {
                                model.dismissModal()
                            }
                        } else {
                            Color.clear.onAppear { model.dismissModal() }
                        }
                    }
                    .id(token)
                case .confirmDeleteCategory(let pinboardID, let name, let token):
                    Group {
                        if let pinboard = model.pinboards.first(where: { $0.id == pinboardID }) {
                            MacClippyConfirmDeleteCategoryEditor(categoryName: name) {
                                model.deletePinboard(pinboard)
                                model.dismissModal()
                            } onCancel: {
                                model.dismissModal()
                            }
                        } else {
                            Color.clear.onAppear { model.dismissModal() }
                        }
                    }
                    .id(token)
                }
            }
            .transition(MacClippyMotion.fadeTransition(reduceMotion: reduceMotion))
            .animation(
                MacClippyMotion.animation(MacClippyMotion.contentAnimation, reduceMotion: reduceMotion),
                value: model.modal
            )
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityFocused($modalAccessibilityFocused)
            .accessibilityLabel(modalAccessibilityLabel(for: modal))
        }
    }

    func modalAccessibilityLabel(for modal: MacClippyDockModal) -> String {
        switch modal {
        case .confirmDeleteItems: return "Permanent deletion confirmation"
        case .choosePinboard: return "Choose a Pinboard"
        case .createCategory:
            return "New category dialog"
        case .renameItem:
            return "Rename clipboard item dialog"
        case .renameCategory:
            return "Rename category dialog"
        case .confirmDeleteCategory:
            return "Delete category confirmation dialog"
        }
    }

}
