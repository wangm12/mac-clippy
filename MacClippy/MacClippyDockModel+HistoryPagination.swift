import Foundation

import MacClippyCore
import MacClippyPlatform

private struct MacClippyHistoryPageRequest: Sendable {
    let pageToken: MacClippyHistoryPageToken
    let query: String
    let session: UInt
    let loadGeneration: UInt
    let cancellationToken: MacClippyCancellationToken
}

enum MacClippyDockHistoryPaginationPolicy {
    static let pageSize = 16
    static let prefetchThreshold = 4
}

extension MacClippyDockModel {
    static let historyPageSize = MacClippyDockHistoryPaginationPolicy.pageSize
    static let historyPrefetchThreshold = MacClippyDockHistoryPaginationPolicy.prefetchThreshold

    func resetHistoryPaginationForReload() {
        historyLoadWorkItem?.cancel()
        historyLoadCancellationToken?.cancel()
        historyLoadWorkItem = nil
        historyLoadCancellationToken = nil
        historyLoadGeneration &+= 1
        historyPageToken = nil
        historyQuery = query
        historyHasMore = true
        historyIsLoadingMore = false
    }

    /// Prefetch the next page before the user reaches the end of the carousel.
    /// Existing card identities stay in the array, so SwiftUI preserves the
    /// user's scroll position while the page is appended.
    func loadMoreHistoryIfNeeded(after itemID: RecordID) {
        guard selectedTab == .history,
              historyHasMore,
              !historyIsLoadingMore,
              historyQuery == query,
              historyPageToken != nil,
              let itemIndex = historyItems.firstIndex(where: { $0.id == itemID }),
              itemIndex >= max(0, historyItems.count - Self.historyPrefetchThreshold) else {
            return
        }

        loadMoreHistoryPage()
    }

    func retryHistoryPage() {
        guard !historyIsLoadingMore else { return }
        guard historyHasMore, historyPageToken != nil else {
            reload()
            return
        }
        clearPageError()
        loadMoreHistoryPage()
    }

    private func loadMoreHistoryPage() {
        guard let pageToken = historyPageToken else { return }
        historyIsLoadingMore = true
        let request = MacClippyHistoryPageRequest(
            pageToken: pageToken,
            query: historyQuery,
            session: sessionGeneration,
            loadGeneration: historyLoadGeneration,
            cancellationToken: MacClippyCancellationToken()
        )
        historyLoadCancellationToken = request.cancellationToken
        let workItem = makeHistoryPageWorkItem(request)
        historyLoadWorkItem = MacClippyDispatchWorkItem(workItem)
        workQueue.async(execute: workItem)
    }

    private func makeHistoryPageWorkItem(_ request: MacClippyHistoryPageRequest) -> DispatchWorkItem {
        let runtimeReference = runtime
        return DispatchWorkItem { [weak self, runtimeReference, request] in
            guard !request.cancellationToken.isCancelled else { return }
            let result = Result {
                try runtimeReference.historyPage(
                    limit: Self.historyPageSize,
                    query: request.query,
                    pageToken: request.pageToken,
                    shouldCancel: { request.cancellationToken.isCancelled }
                )
            }
            guard !request.cancellationToken.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                self?.applyHistoryPageResult(
                    result,
                    request: request
                )
            }
        }
    }

    private func applyHistoryPageResult(
        _ result: Result<MacClippyHistoryPage, Error>,
        request: MacClippyHistoryPageRequest
    ) {
        guard !request.cancellationToken.isCancelled,
              self.sessionGeneration == request.session,
              self.historyLoadGeneration == request.loadGeneration,
              self.historyQuery == request.query,
              self.historyPageToken == request.pageToken else { return }
        historyIsLoadingMore = false
        historyLoadCancellationToken = nil
        switch result {
        case let .success(page):
            clearPageError()
            let existingIDs = Set(historyItems.map(\.id))
            let additions = page.items.filter { !existingIDs.contains($0.id) }
            if !additions.isEmpty {
                historyItems.append(contentsOf: additions)
                rebindSelection()
                recomputeDedupRuns()
            }
            historyPageToken = page.nextPageToken
            historyHasMore = page.nextPageToken != nil
        case let .failure(error):
            if error is MacClippyHistoryPageError {
                // FTS rank order is no longer compatible with this
                // continuation. Restart the current query while preserving
                // the visible snapshot until the replacement page arrives.
                reload()
                return
            }
            // Keep the continuation so the user can retry the failed page;
            // never silently turn a partial history snapshot into a complete
            // one.
            pageError = MacClippyUserFacingError.historyLoad
            if historyItems.isEmpty {
                historyLoadError = MacClippyUserFacingError.historyLoad
            }
        }
    }
}
