import Foundation

import MacClippyCore

extension MacClippyDockModel {
    /// Restarts only the current History query. Pinboard pages and search
    /// state stay in place so an FTS revision change cannot wipe categories.
    func restartHistoryQuery() {
        reloadTask?.cancel()
        reloadTask = nil
        reloadWorkItem?.cancel()
        reloadCancellationToken?.cancel()
        resetHistoryPaginationForReload()
        let cancellationToken = MacClippyCancellationToken()
        reloadCancellationToken = cancellationToken
        requestID += 1
        let currentRequestID = requestID
        let currentHistoryGeneration = historyLoadGeneration
        let query = query
        let runtimeReference = runtime
        isLoading = MacClippyDockSessionOpenPolicy.shouldPublishLoading(
            hasVisibleSnapshot: !historyItems.isEmpty
        )
        clearHistoryError()
        clearPageError()

        let workItem = DispatchWorkItem { [weak self, runtimeReference, cancellationToken] in
            guard !cancellationToken.isCancelled else { return }
            let result = Result {
                try runtimeReference.historyPage(
                    limit: MacClippyDockHistoryPaginationPolicy.pageSize,
                    query: query,
                    shouldCancel: { cancellationToken.isCancelled }
                )
            }
            guard !cancellationToken.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                self?.applyRestartedHistoryPage(
                    result,
                    query: query,
                    requestID: currentRequestID,
                    historyGeneration: currentHistoryGeneration,
                    cancellationToken: cancellationToken
                )
            }
        }
        reloadWorkItem = MacClippyDispatchWorkItem(workItem)
        reloadQueue.async(execute: workItem)
    }

    private func applyRestartedHistoryPage(
        _ result: Result<MacClippyHistoryPage, Error>,
        query: String,
        requestID: Int,
        historyGeneration: UInt,
        cancellationToken: MacClippyCancellationToken
    ) {
        guard !cancellationToken.isCancelled,
              self.requestID == requestID,
              historyLoadGeneration == historyGeneration else { return }
        isLoading = false
        switch result {
        case let .success(page):
            clearHistoryError()
            clearPageError()
            historyItems = page.items
            historyPageToken = page.nextPageToken
            historyHasMore = page.nextPageToken != nil
            historyQuery = query
            if selectedTab == .history {
                focusedIndex = min(focusedIndex, max(0, currentCount - 1))
                rebindSelection()
                recomputeDedupRuns()
            }
        case let .failure(error):
            let message = MacClippyUserFacingError.message(
                for: error,
                fallback: MacClippyUserFacingError.historyLoad
            )
            if historyItems.isEmpty {
                historyLoadError = message
            } else {
                pageError = message
            }
        }
    }
}
