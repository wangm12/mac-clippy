import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import SwiftUI

extension MacClippyDockModel {
    func activate(_ item: MacClippyHistoryEntry, completion: @escaping @MainActor @Sendable () -> Void) {
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else { return }
        focusedIndex = index
        guard item.isPasteable else { return }
        select(item, completion: completion)
    }

    func activate(_ snippet: MacClippySnippetEntry, completion: @escaping @MainActor @Sendable () -> Void) {
        guard let index = visibleSnippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        focusedIndex = index
        select(snippet, completion: completion)
    }

    func focus(_ item: MacClippyHistoryEntry) {
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else { return }
        focusedIndex = index
    }

    func focusAndSelect(_ item: MacClippyHistoryEntry) {
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else { return }
        focusSelection(at: index)
    }

    func ensureFocusedSelection() {
        guard selectedTab != .snippets, currentCount > 0 else { return }
        focusedIndex = min(max(focusedIndex, 0), currentCount - 1)
        if !hasAnySelectedRecords {
            focusSelection(at: focusedIndex)
        }
    }

    func focus(_ snippet: MacClippySnippetEntry) {
        guard let index = visibleSnippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        focusedIndex = index
    }

    func pasteFocused(completion: @escaping @MainActor @Sendable () -> Void) {
        if selectedTab == .snippets {
            guard let snippet = focusedSnippet else { return }
            activate(snippet, completion: completion)
        } else if let item = focusedItem {
            activate(item, completion: completion)
        }
    }

    func activateShortcut(_ number: Int, completion: @escaping @MainActor @Sendable () -> Void) {
        let index = number - 1
        guard index >= 0, index < currentCount else { return }
        focusedIndex = index
        pasteFocused(completion: completion)
    }

    func copyFocused() {
        copyFocused(plain: false)
    }

    func copyFocused(plain: Bool, completion: (@MainActor @Sendable () -> Void)? = nil) {
        let runtimeReference = runtime
        let feedback: MacClippyDockActionFeedback = .copied(plain: plain)
        if selectedTab == .snippets, let snippet = focusedSnippet {
            performWithSideEffect { [runtimeReference] gate in
                try runtimeReference.copy(snippetID: snippet.id, sideEffectGate: gate)
            } onSuccess: { [weak self] in
                self?.showActionFeedback(feedback)
                completion?()
            }
        } else if let item = focusedItem {
            performWithSideEffect { [runtimeReference] gate in
                try runtimeReference.copy(id: item.id, plain: plain, sideEffectGate: gate)
            } onSuccess: { [weak self] in
                self?.showActionFeedback(feedback)
                completion?()
            }
        }
    }

    /// Transformed copy/paste of the focused card. Both act on the focused
    /// clipboard record (the context menu focuses the card before invoking).
    /// Only text/html/rtf records are supported; the runtime rejects image/
    /// files and undecodable payloads with an explicit error, which surfaces
    /// via errorMessage so nothing is silently transformed or dropped. Copy
    /// keeps the dock open (no completion) and shows transformedCopied
    /// feedback, matching copyFocused. Paste uses the same async + session-
    /// generation guard as select(item:completion:) so a stale completion from
    /// a previous dock session cannot close a newly reopened dock, and calls
    /// completion (closing the dock) only on a successful paste.
    func copyFocused(transform: TextTransform) {
        guard let item = focusedItem else { return }
        let runtimeReference = runtime
        let name = transform.displayName
        performWithSideEffect { [runtimeReference] gate in
            try runtimeReference.copy(id: item.id, transform: transform, sideEffectGate: gate)
        } onSuccess: { [weak self] in
            self?.showActionFeedback(.transformedCopied(name: name))
        }
    }

    func pasteFocused(
        transform: TextTransform,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let item = focusedItem else { return }
        let runtimeReference = runtime
        let name = transform.displayName
        let operation = beginUserOperation()
        let session = sessionGeneration
        let sideEffectGate = MacClippyPasteInjectionGate()
        self.sideEffectGate = sideEffectGate
        clearActionError()

        workQueue.async { [weak self, runtimeReference, sideEffectGate] in
            let result = Result {
                try runtimeReference.paste(
                    id: item.id,
                    transform: transform,
                    sideEffectGate: sideEffectGate
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == operation else { return }
                switch result {
                case let .success(pasteResult):
                    self.showActionFeedback(.transformedPasted(name: name, manual: pasteResult == .manualPasteRequired))
                    completion()
                case .failure:
                    self.setActionError(MacClippyUserFacingError.genericAction)
                }
            }
        }
    }

    func togglePinFocused(in pinboardID: RecordID) {
        guard let item = focusedItem else { return }
        let runtimeReference = runtime
        let pinAction = focusedPinAction
        perform { [item] in
            try runtimeReference.togglePin(id: item.id, preferredPinboardID: pinboardID)
            return true
        } onSuccess: { [weak self] in
            guard let self else { return }
            if case let .pin(boardName) = pinAction {
                self.showActionFeedback(.pinChanged(boardName: boardName, isPinned: true))
            } else if case let .unpin(boardName) = pinAction {
                self.showActionFeedback(.pinChanged(boardName: boardName, isPinned: false))
            }
            self.reload()
        }
    }

    func togglePinFocused(completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let item = focusedItem else { return }
        let runtimeReference = runtime
        perform { [item] in
            try runtimeReference.togglePin(id: item.id)
            return true
        } onSuccess: { [weak self] in
            self?.reload()
            completion?()
        }
    }

    // P2a: set or clear the focused card's name. The runtime trims the stored
    // value (blank -> nil removes it), persists it, and reindexes the
    // search store so the name is searchable without losing existing
    // searchable text. The model reports transient name feedback and reloads
    // so the card immediately reflects the new name. Reload is safe: it
    // cancels any in-flight reload and rebinds the selection, so a rename can never
    // leave a stale card or a stale selection.
    func renameFocused(_ name: String?) {
        guard let item = focusedItem else { return }
        renameItem(id: item.id, name: name)
    }

    // P2a: set or clear a name for an arbitrary visible record (used by the
    // rename editor when the edited card is not the focused one).
    func renameItem(id: RecordID, name: String?) {
        let runtimeReference = runtime
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let willClear = (trimmed?.isEmpty ?? true)
        nameOperationGeneration &+= 1
        let nameGeneration = nameOperationGeneration
        let session = sessionGeneration
        clearActionError()

        workQueue.async { [weak self, runtimeReference] in
            let result = Result {
                _ = try runtimeReference.setCustomLabel(id: id, label: name)
                return true
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.sessionGeneration == session,
                      self.nameOperationGeneration == nameGeneration else { return }
                switch result {
                case .success:
                    self.showActionFeedback(.nameSaved(cleared: willClear))
                    self.reload()
                case .failure:
                    self.setActionError(MacClippyUserFacingError.genericAction)
                }
            }
        }
    }

    func pin(
        recordID: RecordID,
        to pinboard: MacClippyPinboardEntry,
        expectedSession: UInt? = nil,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        guard expectedSession == nil || expectedSession == sessionGeneration else {
            completion?(false)
            return
        }
        let runtimeReference = runtime
        perform {
            try runtimeReference.pin(recordID: recordID, to: pinboard.id)
            return true
        } onSuccess: { [weak self] in
            self?.showActionFeedback(.pinnedTo(boardName: pinboard.name))
            self?.reload()
            completion?(true)
        } onFailure: {
            completion?(false)
        }
    }

    func createSnippet(
        from recordID: RecordID,
        expectedSession: UInt? = nil,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        guard expectedSession == nil || expectedSession == sessionGeneration else {
            completion?(false)
            return
        }
        let runtimeReference = runtime
        let session = sessionGeneration
        clearActionError()

        workQueue.async { [weak self, runtimeReference] in
            let result = Result { try runtimeReference.createSnippet(from: recordID) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionGeneration == session else { return }
                switch result {
                case .success:
                    self.showActionFeedback(.snippetCreated)
                    self.reload()
                    completion?(true)
                case let .failure(error):
                    if error is MacClippySnippetCreationError {
                        self.setActionError(MacClippyUserFacingError.snippetTextOnly)
                    } else {
                        self.setActionError(MacClippyUserFacingError.genericAction)
                    }
                    completion?(false)
                }
            }
        }
    }

    func createSnippet(
        name: String,
        trigger: String?,
        body: String,
        onSuccess: (@MainActor @Sendable () -> Void)? = nil,
        onFailure: (@MainActor @Sendable (String) -> Void)? = nil
    ) {
        let runtime = runtime
        let session = sessionGeneration
        clearActionError()

        workQueue.async { [weak self, runtime] in
            let result = Result {
                try runtime.createSnippet(name: name, trigger: trigger, body: body)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionGeneration == session else { return }
                switch result {
                case .success:
                    self.showActionFeedback(.snippetCreated)
                    self.reload()
                    onSuccess?()
                case let .failure(error):
                    let message: String
                    switch error as? MacClippySnippetCreationError {
                    case .invalidName:
                        message = "Enter a name for this snippet."
                    case .emptyBody:
                        message = "Enter some content for this snippet."
                    case .duplicateTrigger:
                        message = "That trigger is already in use."
                    default:
                        message = MacClippyUserFacingError.genericAction
                    }
                    onFailure?(message)
                }
            }
        }
    }

    func createPinboard(
        name: String,
        color: String,
        onComplete: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let runtime = runtime
        let session = sessionGeneration
        workQueue.async { [weak self, runtime] in
            let result = Result { try runtime.createPinboard(name: trimmedName, color: color) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionGeneration == session else { return }
                switch result {
                case let .success(board):
                    self.selectTab(.pinboard(board.id))
                    self.reload()
                    onComplete?(true)
                case .failure:
                    self.setActionError(MacClippyUserFacingError.genericAction)
                    onComplete?(false)
                }
            }
        }
    }

    func renamePinboard(_ pinboard: MacClippyPinboardEntry, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let runtime = runtime
        perform {
            try runtime.renamePinboard(id: pinboard.id, to: trimmedName)
            return true
        } onSuccess: { [weak self] in
            self?.reload()
        }
    }

    func setPinboardColor(_ pinboard: MacClippyPinboardEntry, to color: String) {
        let runtime = runtime
        perform {
            try runtime.setPinboardColor(id: pinboard.id, color: color)
            return true
        } onSuccess: { [weak self] in
            self?.reload()
        }
    }

    func deletePinboard(_ pinboard: MacClippyPinboardEntry) {
        let runtime = runtime
        perform {
            try runtime.deletePinboard(id: pinboard.id)
            return true
        } onSuccess: { [weak self] in
            self?.reload()
        }
    }

    func isPinned(_ itemID: RecordID, in pinboard: MacClippyPinboardEntry) -> Bool {
        pinboard.board.itemIDs.contains(itemID)
    }

    func deleteFocused() {
        let runtime = runtime
        if selectedTab == .snippets, let snippet = focusedSnippet {
            perform {
                try runtime.delete(snippetID: snippet.id)
                return true
            } onSuccess: { [weak self] in
                self?.showActionFeedback(.deleted)
                self?.reload()
            }
        } else if let item = focusedItem {
            perform {
                try runtime.delete(id: item.id)
                return true
            } onSuccess: { [weak self] in
                self?.showActionFeedback(.deleted)
                self?.reload()
            }
        } else {
            return
        }
    }

}
