import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyDockModel {
    func resetPinboardSearchState() {
        pinboardSearchWorkItem?.cancel()
        pinboardSearchCancellationToken?.cancel()
        pinboardSearchWorkItem = nil
        pinboardSearchCancellationToken = nil
        pinboardSearchGeneration &+= 1
        pinboardSearchBoardID = nil
        pinboardSearchQuery = ""
        pinboardSearchPageToken = nil
        pinboardSearchHasMore = false
        pinboardSearchItems = []
        pinboardSearchIsLoading = false
        pinboardSearchError = nil
        clearPageError()
    }

    func schedulePinboardSearch() {
        guard case let .pinboard(boardID) = selectedTab else {
            resetPinboardSearchState()
            return
        }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            resetPinboardSearchState()
            return
        }
        resetPinboardSearchState()
        pinboardSearchBoardID = boardID
        pinboardSearchQuery = query
        pinboardSearchHasMore = true
        loadPinboardSearchPage(reset: true)
    }

    func loadMorePinboardSearchIfNeeded(after itemID: RecordID) {
        guard case let .pinboard(boardID) = selectedTab,
              pinboardSearchBoardID == boardID,
              pinboardSearchQuery == query,
              pinboardSearchHasMore,
              !pinboardSearchIsLoading,
              let itemIndex = pinboardSearchItems.firstIndex(where: { $0.id == itemID }),
              itemIndex >= max(
                  0,
                  pinboardSearchItems.count - MacClippyDockHistoryPaginationPolicy.prefetchThreshold
              ) else {
            return
        }
        loadPinboardSearchPage(reset: false)
    }

    func retryPinboardSearchPage() {
        guard case .pinboard = selectedTab,
              pinboardSearchBoardID != nil,
              pinboardSearchHasMore,
              !pinboardSearchIsLoading else { return }
        clearPageError()
        loadPinboardSearchPage(reset: false)
    }

    private func loadPinboardSearchPage(reset: Bool) {
        guard case let .pinboard(boardID) = selectedTab,
              pinboardSearchBoardID == boardID else { return }
        pinboardSearchWorkItem?.cancel()
        pinboardSearchCancellationToken?.cancel()
        let cancellationToken = MacClippyCancellationToken()
        pinboardSearchCancellationToken = cancellationToken
        pinboardSearchIsLoading = true
        pinboardSearchError = nil
        clearPageError()
        pinboardSearchGeneration &+= 1
        let generation = pinboardSearchGeneration
        let requestQuery = pinboardSearchQuery
        let requestPageToken = reset ? nil : pinboardSearchPageToken
        let runtimeReference = runtime
        let workItem = DispatchWorkItem { [weak self, runtimeReference, cancellationToken] in
            guard !cancellationToken.isCancelled else { return }
            let result = Result {
                try runtimeReference.pinboardSearchPage(
                    pinboardID: boardID,
                    query: requestQuery,
                    limit: MacClippyDockHistoryPaginationPolicy.pageSize,
                    pageToken: requestPageToken,
                    shouldCancel: { cancellationToken.isCancelled }
                )
            }
            guard !cancellationToken.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !cancellationToken.isCancelled,
                      self.pinboardSearchGeneration == generation,
                      self.pinboardSearchBoardID == boardID,
                      self.pinboardSearchQuery == requestQuery,
                      self.selectedTab == .pinboard(boardID) else { return }
                self.pinboardSearchWorkItem = nil
                self.pinboardSearchCancellationToken = nil
                self.pinboardSearchIsLoading = false
                self.applyPinboardSearchResult(result, reset: reset)
            }
        }
        pinboardSearchWorkItem = MacClippyDispatchWorkItem(workItem)
        workQueue.async(execute: workItem)
    }

    private func applyPinboardSearchResult(
        _ result: Result<MacClippyPinboardSearchPage, Error>,
        reset: Bool
    ) {
        switch result {
        case let .success(page):
            clearPageError()
            if reset { pinboardSearchItems = [] }
            let existingIDs = Set(pinboardSearchItems.map(\.id))
            pinboardSearchItems.append(contentsOf: page.items.filter { !existingIDs.contains($0.id) })
            pinboardSearchPageToken = page.nextPageToken
            pinboardSearchHasMore = page.nextPageToken != nil
            rebindSelection()
            recomputeDedupRuns()
        case let .failure(error):
            if error is MacClippyPinboardSearchPageError {
                schedulePinboardSearch()
                return
            }
            // Keep the cursor and continuation so the same page can be
            // retried without losing the already visible matches.
            pinboardSearchHasMore = true
            pinboardSearchError = MacClippyUserFacingError.historyLoad
            pageError = MacClippyUserFacingError.historyLoad
        }
    }
}
