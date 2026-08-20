import AppKit
import Foundation
import SwiftUI

import MacClippyCore
import MacClippyPlatform

private func macClippyLoadDockSnapshot(
    runtime: MacClippyRuntime,
    query: String,
    includeStaticData: Bool,
    cancellationToken: MacClippyCancellationToken
) -> Result<MacClippyDockModel.Snapshot, Error> {
    Result {
        MacClippyDockModel.Snapshot(
            history: try runtime.historyPage(
                limit: MacClippyDockHistoryPaginationPolicy.pageSize,
                query: query,
                shouldCancel: { cancellationToken.isCancelled }
            ),
            snippets: includeStaticData ? try runtime.snippets() : nil,
            pinboards: includeStaticData ? try runtime.pinboards() : nil
        )
    }
}

extension MacClippyDockModel {
    func handleExternalHistoryChange() {
        guard isSessionActive, selectedTab == .history else { return }
        reload(includeStaticData: false)
    }

    var visibleItems: [MacClippyHistoryEntry] {
        switch selectedTab {
        case .history:
            if historyQuery == query, !isLoading {
                return historyItems
            }
            return filter(historyItems, by: query)
        case .snippets: return []
        case let .pinboard(id):
            return MacClippyDockPinboardVisibleItems.resolve(
                MacClippyDockPinboardVisibleItemsState(
                    query: query,
                    boardID: id,
                    source: pinboards.first(where: { $0.id == id })?.items ?? [],
                    searchBoardID: pinboardSearchBoardID,
                    searchQuery: pinboardSearchQuery,
                    searchItems: pinboardSearchItems,
                    isLoading: pinboardSearchIsLoading
                )
            )
        }
    }

    var visibleSnippets: [MacClippySnippetEntry] {
        selectedTab == .snippets ? filteredSnippets : []
    }

    func scheduleSnippetFilter() {
        snippetFilterWorkItem?.cancel()
        snippetFilterRequestID &+= 1
        let requestID = snippetFilterRequestID
        guard selectedTab == .snippets else {
            filteredSnippets = []
            return
        }

        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = snippets
        guard !normalizedQuery.isEmpty else {
            filteredSnippets = source
            return
        }

        let parsed = MacClippySearchGrammar.parse(normalizedQuery)
        let workItem = DispatchWorkItem { [weak self, source, parsed] in
            let filtered: [MacClippySnippetEntry]
            if parsed.bareTerms.isEmpty {
                filtered = parsed.hasStructuredClauses ? [] : source
            } else {
                filtered = source.filter { snippet in
                    MacClippySearchQuery.allTerms(parsed.bareTerms, appearIn: [snippet.normalizedSearchText])
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.snippetFilterRequestID == requestID else { return }
                self.filteredSnippets = filtered
            }
        }
        snippetFilterWorkItem = MacClippyDispatchWorkItem(workItem)
        snippetFilterQueue.async(execute: workItem)
    }

    var selectedPinboardName: String? {
        guard case let .pinboard(id) = selectedTab else { return nil }
        return pinboards.first(where: { $0.id == id })?.name
    }

    var focusedItem: MacClippyHistoryEntry? {
        guard selectedTab != .snippets else { return nil }
        return visibleItems.indices.contains(focusedIndex) ? visibleItems[focusedIndex] : nil
    }

    var focusedSnippet: MacClippySnippetEntry? {
        guard selectedTab == .snippets else { return nil }
        return visibleSnippets.indices.contains(focusedIndex) ? visibleSnippets[focusedIndex] : nil
    }

    var focusedPreviewTarget: MacClippyDockPreviewTarget? {
        if let focusedSnippet { return .snippet(focusedSnippet.id) }
        if let focusedItem { return .item(focusedItem.id) }
        return nil
    }

    var focusedPinAction: MacClippyDockPinAction? {
        guard let focusedItem else { return nil }
        return MacClippyDockPinResolver.action(
            for: focusedItem.id,
            selectedTab: selectedTab,
            pinboards: pinboards
        )
    }

    // Whether the multi-select action surface should be shown. The bar shows
    // only when MORE THAN ONE card is selected (count > 1): a single focused
    // card is not a "selection group" and should not show the multi-action bar.
    // A plain click collapses a multi-selection to one focused card, which
    // correctly dismisses the bar (intentional macOS semantic). Cmd-click
    // toggles keep the bar mounted while count > 1. The bar uses the same short
    // ease-out family as the rest of the dock, so dismissal stays smooth
    // without overshoot.
    var hasMultipleSelection: Bool {
        selectedTab != .snippets && selectionCount > 1
    }

    var selectionCount: Int {
        selectedTab == .snippets ? 0 : (allSelectedRecordIDs?.count ?? selection.count)
    }

    // The target pinboard for a batch pin: the currently-viewed pinboard tab
    // if the user is looking at one, otherwise the first pinboard. nil when no
    // pinboard exists. Used by Cmd+P and the Pin all action.
    var batchPinTarget: MacClippyPinboardEntry? {
        if case let .pinboard(id) = selectedTab,
           let board = pinboards.first(where: { $0.id == id }) {
            return board
        }
        return pinboards.first
    }

    var currentSessionGeneration: UInt { sessionGeneration }

    func reload(includeStaticData: Bool = true) {
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
        pinboardLoadGeneration &+= 1
        pinboardLoadingIDs.removeAll()
        resetPinboardSearchState()
        let query = query
        let runtimeReference = runtime
        isLoading = true
        clearHistoryError()
        clearPageError()

        let workItem = DispatchWorkItem { [weak self, runtimeReference, cancellationToken] in
            guard !cancellationToken.isCancelled else { return }
            let result = macClippyLoadDockSnapshot(
                runtime: runtimeReference,
                query: query,
                includeStaticData: includeStaticData,
                cancellationToken: cancellationToken
            )
            guard !cancellationToken.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !cancellationToken.isCancelled,
                      self.requestID == currentRequestID,
                      self.historyLoadGeneration == currentHistoryGeneration else { return }
                self.isLoading = false
                self.applyReloadResult(result, query: query)
            }
        }
        reloadWorkItem = MacClippyDispatchWorkItem(workItem)
        reloadQueue.async(execute: workItem)
    }

    private func applyReloadResult(
        _ result: Result<Snapshot, Error>,
        query: String
    ) {
        switch result {
        case let .success(snapshot):
            clearHistoryError()
            clearPageError()
            historyItems = snapshot.history.items
            historyPageToken = snapshot.history.nextPageToken
            historyHasMore = snapshot.history.nextPageToken != nil
            historyQuery = query
            if let snippets = snapshot.snippets {
                self.snippets = snippets
                scheduleSnippetFilter()
            }
            if let pinboards = snapshot.pinboards {
                self.pinboards = pinboards
            }
            if case .pinboard = selectedTab,
               !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                schedulePinboardSearch()
            }
            reconcileSelectedTab()
            focusedIndex = min(focusedIndex, max(0, currentCount - 1))
            rebindSelection()
            if selection.isEmpty, currentCount > 0, selectedTab != .snippets {
                focusSelection(at: focusedIndex)
            }
            recomputeDedupRuns()
        case let .failure(error):
            // Keep the last successful snapshot visible. A transient
            // query/database failure should not destroy current content;
            // the error banner and next reload provide recovery.
            let message = MacClippyUserFacingError.message(for: error, fallback: MacClippyUserFacingError.historyLoad)
            if historyItems.isEmpty {
                historyLoadError = message
            } else {
                pageError = message
            }
        }
    }

    func scheduleReload() {
        reloadTask?.cancel()
        // Search filtering for snippets and pinboards is local. Only history
        // needs a database query when the user types; Pinboard queries use a
        // bounded Runtime scan so matches outside the initial 64 cards are
        // still searchable without reloading every static surface.
        guard selectedTab == .history || isPinboardTab else { return }
        let signpostID = MacClippyPerformance.begin("search_keystroke")
        reloadTask = Task { @MainActor [weak self] in
            defer { MacClippyPerformance.end("search_keystroke", id: signpostID) }
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            if self.isPinboardTab {
                self.schedulePinboardSearch()
            } else {
                self.reload(includeStaticData: false)
            }
        }
    }

    private var isPinboardTab: Bool {
        if case .pinboard = selectedTab { return true }
        return false
    }

    func requestSearchFocus() {
        searchFocusRequest &+= 1
    }

    func resetSearchFocus() {
        searchFocusReset &+= 1
    }

    func setErrorForDetails(_ message: String) {
        actionError = message
    }

    func appendSearchText(_ text: String) {
        query.append(text)
    }

    func deleteSearchCharacter() {
        guard !query.isEmpty else { return }
        query.removeLast()
    }

    func loadPreview(
        for target: MacClippyDockPreviewTarget,
        completion: @escaping @MainActor @Sendable (Result<MacClippyRuntimePreviewPayload, Error>) -> Void
    ) {
        previewWorkItem?.cancel()
        previewCancellationToken?.cancel()
        let cancellationToken = MacClippyCancellationToken()
        previewCancellationToken = cancellationToken
        let runtimeReference = runtime
        let workItem = DispatchWorkItem { [runtimeReference, cancellationToken] in
            guard !cancellationToken.isCancelled else { return }
            let result = Result {
                switch target {
                case let .item(id):
                    try runtimeReference.preview(id: id)
                case let .snippet(id):
                    try runtimeReference.preview(snippetID: id)
                }
            }
            guard !cancellationToken.isCancelled else { return }
            DispatchQueue.main.async {
                guard !cancellationToken.isCancelled else { return }
                completion(result)
            }
        }
        previewWorkItem = MacClippyDispatchWorkItem(workItem)
        previewQueue.async(execute: workItem)
    }

    func loadDetails(
        for id: RecordID,
        completion: @escaping @MainActor @Sendable (Result<MacClippyItemDetails, Error>) -> Void
    ) {
        detailsCancellationToken?.cancel()
        let cancellationToken = MacClippyCancellationToken()
        detailsCancellationToken = cancellationToken
        let runtimeReference = runtime
        let session = sessionGeneration
        workQueue.async { [runtimeReference, cancellationToken] in
            guard !cancellationToken.isCancelled else { return }
            let result = Result { try runtimeReference.details(id: id) }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !cancellationToken.isCancelled,
                      self.sessionGeneration == session else { return }
                completion(result)
            }
        }
    }

    func editDetails(
        id: RecordID,
        text: String,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        let runtimeReference = runtime
        let session = sessionGeneration
        workQueue.async { [weak self, runtimeReference] in
            let result = Result { _ = try runtimeReference.edit(id: id, text: text) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionGeneration == session else { return }
                completion(result.map { _ in () })
                if case .success = result {
                    self.reload()
                }
            }
        }
    }

    func renameDetails(
        id: RecordID,
        name: String?,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        let runtimeReference = runtime
        let session = sessionGeneration
        workQueue.async { [weak self, runtimeReference] in
            let result = Result { _ = try runtimeReference.setCustomLabel(id: id, label: name) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sessionGeneration == session else { return }
                completion(result.map { _ in () })
                if case .success = result {
                    self.reload()
                }
            }
        }
    }

}
