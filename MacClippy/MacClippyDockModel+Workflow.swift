import Foundation
import MacClippyCore

extension MacClippyDockModel {
    var selectionIsReady: Bool {
        !isSelectingAllMatches && selectAllWorkItem == nil && !allSelectionFailed
    }

    var canMergeSelection: Bool {
        guard !isSelecting, selectionIsReady else { return false }
        if allSelectedRecordIDs != nil { return allSelectionCanMerge }
        let items = visibleItems.filter { isSelected($0.id) }
        return !items.isEmpty && items.allSatisfy(\.supportsPlainCopy)
    }

    func requestDeleteSelected() {
        guard selectionIsReady else { return }
        let ids = hasAnySelectedRecords ? orderedSelectedRecordIDs : focusedItem.map { [$0.id] } ?? []
        requestDeleteRecords(ids: ids)
    }

    func requestDeleteRecords(ids: [RecordID]) {
        guard !ids.isEmpty else { return }
        let includesPinned = pinboards.contains { !Set($0.board.itemIDs).isDisjoint(with: ids) }
        if ids.count == 1, !includesPinned {
            deleteRecord(id: ids[0])
        } else {
            modalPresentationToken += 1
            modal = .confirmDeleteItems(
                ids: ids, includesPinned: includesPinned, token: modalPresentationToken)
        }
    }

    func requestPinSelection(ids: [RecordID]? = nil) {
        if ids == nil {
            guard selectionIsReady, selectedTab != .snippets else { return }
        }
        let fallback = orderedSelectedRecordIDs.isEmpty ? focusedItem.map { [$0.id] } ?? [] : orderedSelectedRecordIDs
        let ids = ids ?? fallback
        guard !ids.isEmpty, !pinboards.isEmpty else { return }
        modalPresentationToken += 1
        modal = .choosePinboard(ids: ids, token: modalPresentationToken)
    }

    func copyRecord(
        id: RecordID, plain: Bool = false, completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let runtimeReference = runtime
        performWithSideEffect { gate in
            try runtimeReference.copy(id: id, plain: plain, sideEffectGate: gate)
        } onSuccess: { [weak self] in
            self?.showActionFeedback(.copied(plain: plain))
            completion?()
        }
    }

    func copyTarget(
        _ target: MacClippyDockPreviewTarget, completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        switch target {
        case .item(let id): copyRecord(id: id, completion: completion)
        case .snippet(let id):
            let runtimeReference = runtime
            performWithSideEffect { gate in
                try runtimeReference.copy(snippetID: id, sideEffectGate: gate)
            } onSuccess: { [weak self] in
                self?.showActionFeedback(.copied(plain: false))
                completion?()
            }
        }
    }

    func pasteTarget(
        _ target: MacClippyDockPreviewTarget, plain: Bool? = nil,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        switch target {
        case .item(let id): selectRecord(id: id, plain: plain, completion: completion)
        case .snippet(let id): selectSnippet(id: id, completion: completion)
        }
    }

    func deleteRecord(id: RecordID) {
        let runtimeReference = runtime
        perform {
            try runtimeReference.delete(id: id)
            return true
        } onSuccess: { [weak self] in
            self?.showActionFeedback(.deleted)
            self?.reload()
        }
    }

    func deleteSnippet(id: RecordID) {
        let runtimeReference = runtime
        perform {
            try runtimeReference.delete(snippetID: id)
            return true
        } onSuccess: { [weak self] in
            self?.showActionFeedback(.deleted)
            self?.reload()
        }
    }

    func updateSnippet(
        id: RecordID, draft: MacClippySnippetDraft,
        onSuccess: @escaping @MainActor @Sendable () -> Void,
        onFailure: @escaping @MainActor @Sendable (String) -> Void
    ) {
        let runtimeReference = runtime
        let session = sessionGeneration
        workQueue.async { [weak self] in
            let result = Result {
                try runtimeReference.updateSnippet(
                    id: id, name: draft.name, trigger: draft.trigger, body: draft.body, folder: draft.folder
                )
            }
            MacClippyMainHop.async {
                switch result {
                case .success(let snippet):
                    if let self, self.sessionGeneration == session {
                        if let index = self.snippets.firstIndex(where: { $0.id == snippet.id }) {
                            self.snippets[index] = snippet
                        }
                        self.showActionFeedback(.snippetCreated)
                        self.reload()
                        self.snippetUpdateHandler?(snippet.id)
                    }
                    onSuccess()
                case .failure(let error):
                    onFailure(MacClippySnippetFormError.message(for: error))
                }
            }
        }
    }
}

enum MacClippySnippetFormError {
    static func message(for error: Error) -> String {
        switch error as? MacClippySnippetCreationError {
        case .invalidName: "Enter a name for this snippet."
        case .emptyBody: "Enter some content for this snippet."
        case .duplicateTrigger: "That trigger is already in use."
        default: MacClippyUserFacingError.genericAction
        }
    }
}
