import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyDockModel {
    func rebuildCategoryMembershipIndex() {
        var index: [RecordID: [MacClippyDockCategoryPresentation]] = [:]

        for pinboard in pinboards {
            let category = MacClippyDockCategoryPresentation(
                id: pinboard.id,
                name: pinboard.name,
                colorHex: pinboard.colorHex
            )
            for itemID in pinboard.board.itemIDs
            where !index[itemID, default: []].contains(where: { $0.id == category.id }) {
                index[itemID, default: []].append(category)
            }
        }

        categoryMembershipsByItemID = index
    }

    func categories(for itemID: RecordID) -> [MacClippyDockCategoryPresentation] {
        categoryMembershipsByItemID[itemID] ?? []
    }

    func isPinned(_ itemID: RecordID, in pinboard: MacClippyPinboardEntry) -> Bool {
        pinboard.board.itemIDs.contains(itemID)
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
        } onStale: {
            completion?(false)
        }
    }

    func unpin(_ itemID: RecordID, from pinboardID: RecordID) {
        let runtimeReference = runtime
        let boardName = pinboards.first(where: { $0.id == pinboardID })?.name ?? "List"
        perform {
            try runtimeReference.unpin(recordID: itemID, from: pinboardID)
            return true
        } onSuccess: { [weak self] in
            guard let self else { return }
            self.showActionFeedback(.pinChanged(boardName: boardName, isPinned: false))
            self.reload()
        }
    }

    func unpinSelected() {
        guard selectionIsReady else { return }
        guard case let .pinboard(boardID) = selectedTab, hasAnySelectedRecords else { return }
        let orderedIDs = orderedSelectedRecordIDs
        guard !orderedIDs.isEmpty else { return }
        let boardName = pinboards.first(where: { $0.id == boardID })?.name ?? "List"
        let runtimeReference = runtime
        perform {
            for id in orderedIDs {
                try runtimeReference.unpin(recordID: id, from: boardID)
            }
            return true
        } onSuccess: { [weak self] in
            guard let self else { return }
            self.clearSelection()
            self.showActionFeedback(.pinChanged(boardName: boardName, isPinned: false))
            self.reload()
        }
    }

    func createPinboard(
        name: String,
        color: String,
        modalToken: UInt,
        onComplete: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        guard modal == .createCategory(token: modalToken), !isCreatingPinboard else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            onComplete?(false)
            return
        }
        let runtime = runtime
        let session = sessionGeneration
        pinboardCreation = (session: session, modalToken: modalToken)
        workQueue.async { [weak self, runtime] in
            let result = Result { try runtime.createPinboard(name: trimmedName, color: color) }
            MacClippyMainHop.async { [weak self] in
                guard let self, self.pinboardCreation?.session == session,
                      self.pinboardCreation?.modalToken == modalToken else { return }
                self.pinboardCreation = nil
                guard self.sessionGeneration == session,
                      self.modal == .createCategory(token: modalToken) else { return }
                switch result {
                case let .success(board):
                    self.selectTab(.pinboard(board.id))
                    self.reload()
                    self.dismissModal()
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
}
