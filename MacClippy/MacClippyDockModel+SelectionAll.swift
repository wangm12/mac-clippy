import Foundation

import MacClippyCore
import MacClippyPlatform

private struct MacClippySelectAllRequest {
    let session: UInt
    let query: String
    let tab: MacClippyDockTab
    let generation: UInt
    let cancellationToken: MacClippyCancellationToken
}

extension MacClippyDockModel {
    func startSelectAllRequest() {
        let request = MacClippySelectAllRequest(
            session: sessionGeneration,
            query: query,
            tab: selectedTab,
            generation: selectAllGeneration,
            cancellationToken: MacClippyCancellationToken()
        )
        let runtimeReference = runtime
        selectAllCancellationToken = request.cancellationToken
        let workItem = DispatchWorkItem { [runtimeReference, request] in
            guard !request.cancellationToken.isCancelled else { return }
            let result: Result<[RecordID], Error> = Result {
                switch request.tab {
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
            }
            guard !request.cancellationToken.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
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
        _ result: Result<[RecordID], Error>,
        request: MacClippySelectAllRequest
    ) {
        guard !request.cancellationToken.isCancelled,
              sessionGeneration == request.session,
              selectAllGeneration == request.generation,
              selectedTab == request.tab,
              query == request.query else { return }
        selectAllWorkItem = nil
        selectAllCancellationToken = nil
        switch result {
        case let .success(ids):
            allSelectedRecordIDs = ids
            allSelectedRecordIDSet = Set(ids)
            rebindSelection()
            if ids.isEmpty {
                selection = MacClippyDockSelectionPolicy.clearingSelection(selection)
            }
        case .failure:
            setActionError(MacClippyUserFacingError.genericAction)
        }
    }
}
