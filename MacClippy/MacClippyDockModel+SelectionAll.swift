import Foundation

import MacClippyCore
import MacClippyPlatform

private struct MacClippySelectAllSnapshot {
    let ids: [RecordID]
    let canMerge: Bool
}

private struct MacClippySelectAllRequest {
    let session: UInt
    let query: String
    let tab: MacClippyDockTab
    let generation: UInt
    let cancellationToken: MacClippyCancellationToken
}

extension MacClippyDockModel {
    func startSelectAllRequest() {
        isSelectingAllMatches = true
        let request = MacClippySelectAllRequest(
            session: sessionGeneration,
            query: query,
            tab: selectedTab,
            generation: selectAllGeneration,
            cancellationToken: MacClippyCancellationToken()
        )
        let runtimeReference = runtime
        selectAllCancellationToken = request.cancellationToken
        let workItem = DispatchWorkItem { [weak self, runtimeReference, request] in
            guard !request.cancellationToken.isCancelled else { return }
            let result: Result<MacClippySelectAllSnapshot, Error> = Result {
                let ids: [RecordID] = switch request.tab {
                case .history:
                    try runtimeReference.historyRecordIDs(
                        query: request.query,
                        shouldCancel: { request.cancellationToken.isCancelled }
                    )
                case let .pinboard(pinboardID):
                    try runtimeReference.pinboardRecordIDs(
                        pinboardID: pinboardID,
                        query: request.query,
                        shouldCancel: { request.cancellationToken.isCancelled }
                    )
                case .snippets:
                    []
                }
                let canMerge = try runtimeReference.canMergeRecords(
                    ids: ids, shouldCancel: { request.cancellationToken.isCancelled }
                )
                return MacClippySelectAllSnapshot(ids: ids, canMerge: canMerge)
            }
            guard !request.cancellationToken.isCancelled else { return }
            MacClippyMainHop.async { [weak self] in
                self?.applySelectAllResult(
                    result,
                    request: request
                )
            }
        }
        selectAllWorkItem = MacClippyDispatchWorkItem(workItem)
        workQueue.async(execute: workItem)
    }

    private func applySelectAllResult(
        _ result: Result<MacClippySelectAllSnapshot, Error>,
        request: MacClippySelectAllRequest
    ) {
        guard !request.cancellationToken.isCancelled,
              sessionGeneration == request.session,
              selectAllGeneration == request.generation,
              selectedTab == request.tab,
              query == request.query else { return }
        selectAllWorkItem = nil
        isSelectingAllMatches = false
        selectAllCancellationToken = nil
        switch result {
        case let .success(snapshot):
            let ids = snapshot.ids
            allSelectionCanMerge = snapshot.canMerge
            allSelectedRecordIDs = ids
            allSelectedRecordIDSet = Set(ids)
            rebindSelection()
            if ids.isEmpty {
                selection = MacClippyDockSelectionPolicy.clearingSelection(selection)
            }
        case let .failure(error):
            // A failed full scope must never fall back to the first page.
            // Explicit selection, cancel, a new query or retry clears failure.
            clearSelectionState()
            allSelectionFailed = true
            setActionError(MacClippyUserFacingError.message(for: error))
        }
    }
}
