import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import SwiftUI

extension MacClippyDockModel {
    func selectTab(_ tab: MacClippyDockTab) {
        guard tab != selectedTab else { return }
        let wasSnippets = selectedTab == .snippets
        invalidateAllSelectionScope()
        selectedTab = tab
        focusedIndex = 0
        clearAllErrors()
        if case .pinboard = tab {
            schedulePinboardSearch()
        } else {
            resetPinboardSearchState()
        }
        if tab == .history,
           !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleReload()
        }
        // Clearing the selection on a tab switch keeps the multi-select surface
        // scoped to one visible list; a stale selection from the previous tab
        // would reference IDs that are not in the new visible list.
        selection = MacClippyDockSelectionState()
        if tab == .snippets || wasSnippets {
            scheduleSnippetFilter()
        }
        recomputeDedupRuns()
    }

    func loadMorePinboardIfNeeded(after itemID: RecordID) {
        guard case let .pinboard(pinboardID) = selectedTab,
              let boardIndex = pinboards.firstIndex(where: { $0.id == pinboardID }) else { return }
        let board = pinboards[boardIndex]
        guard board.items.last?.id == itemID,
              board.nextPageToken != nil,
              pinboardLoadingIDs.insert(pinboardID).inserted else { return }
        loadPinboardItemsPage(pinboardID: pinboardID, pageToken: board.nextPageToken)
    }

    func retryPinboardItemPage() {
        guard case let .pinboard(pinboardID) = selectedTab,
              pinboardItemPageRetryToken != nil,
              pinboardLoadingIDs.insert(pinboardID).inserted else { return }
        clearPageError()
        loadPinboardItemsPage(pinboardID: pinboardID, pageToken: pinboardItemPageRetryToken)
    }

    func retryCurrentPage() {
        switch selectedTab {
        case .history:
            retryHistoryPage()
        case .snippets:
            break
        case .pinboard:
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                retryPinboardItemPage()
            } else {
                retryPinboardSearchPage()
            }
        }
    }

    private func loadPinboardItemsPage(
        pinboardID: RecordID,
        pageToken: MacClippyPinboardSearchPageToken?,
        reset: Bool = false
    ) {
        pinboardItemPageRetryToken = reset ? nil : pageToken
        let session = sessionGeneration
        let loadGeneration = pinboardLoadGeneration
        let runtimeReference = runtime
        workQueue.async { [weak self, runtimeReference] in
            let result = Result {
                try runtimeReference.pinboardItemsPage(
                    pinboardID: pinboardID,
                    pageToken: pageToken
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.sessionGeneration == session,
                      self.pinboardLoadGeneration == loadGeneration else { return }
                self.pinboardLoadingIDs.remove(pinboardID)
                guard
                    case .pinboard(pinboardID) = self.selectedTab,
                    self.pinboards.contains(where: { $0.id == pinboardID }) else { return }
                switch result {
                case let .success(page):
                    self.applyPinboardItemsPage(
                        page,
                        pinboardID: pinboardID,
                        pageToken: pageToken,
                        reset: reset
                    )
                case let .failure(error):
                    if error is MacClippyPinboardSearchPageError {
                        self.restartPinboardItemQuery(pinboardID: pinboardID)
                        return
                    }
                    self.pageError = MacClippyUserFacingError.message(
                        for: error,
                        fallback: MacClippyUserFacingError.historyLoad
                    )
                }
            }
        }
    }

    private func applyPinboardItemsPage(
        _ page: MacClippyPinboardSearchPage,
        pinboardID: RecordID,
        pageToken: MacClippyPinboardSearchPageToken?,
        reset: Bool = false
    ) {
        guard let currentIndex = pinboards.firstIndex(where: { $0.id == pinboardID }) else { return }
        clearPageError()
        let current = pinboards[currentIndex]
        let sourceItems = reset ? [] : current.items
        let existingIDs = Set(sourceItems.map(\.id))
        let additions = page.items.filter { !existingIDs.contains($0.id) }
        pinboards[currentIndex] = MacClippyPinboardEntry(
            board: current.board,
            items: sourceItems + additions,
            itemCount: current.itemCount,
            nextPageToken: page.nextPageToken
        )
        if additions.isEmpty,
           let nextToken = page.nextPageToken,
           nextToken.memberOffset > (pageToken?.memberOffset ?? -1) {
            guard pinboardLoadingIDs.insert(pinboardID).inserted else { return }
            loadPinboardItemsPage(pinboardID: pinboardID, pageToken: nextToken)
            return
        }
        pinboardItemPageRetryToken = nil
        rebindSelection()
        recomputeDedupRuns()
    }

    private func restartPinboardItemQuery(pinboardID: RecordID) {
        pinboardItemPageRetryToken = nil
        clearPageError()
        guard pinboardLoadingIDs.insert(pinboardID).inserted else { return }
        loadPinboardItemsPage(pinboardID: pinboardID, pageToken: nil, reset: true)
    }

    /// Recompute the consecutive-duplicate run counts for the current visible
    /// list. O(n) once per list change; the card view then reads an O(1) lookup.
    /// A run is a maximal group of adjacent items with the same contentKind +
    /// preview. Only the first item of each run gets a count > 1 (the badge
    /// host); followers map to 1 so they show no badge.
    func recomputeDedupRuns() {
        let items = visibleItems
        guard !items.isEmpty else {
            if !dedupRunCounts.isEmpty {
                dedupRunCounts = [:]
            }
            return
        }
        var counts: [RecordID: Int] = [:]
        var runStart = 0
        for itemIndex in 1 ... items.count {
            let breaksRun = (itemIndex == items.count)
                || items[itemIndex].contentKind != items[runStart].contentKind
                || MacClippyFilePresentation.dedupKey(
                    preview: items[itemIndex].preview,
                    fileURLs: items[itemIndex].fileURLs
                ) != MacClippyFilePresentation.dedupKey(
                    preview: items[runStart].preview,
                    fileURLs: items[runStart].fileURLs
                )
            if breaksRun {
                let runLength = itemIndex - runStart
                counts[items[runStart].id] = runLength
                runStart = itemIndex
            }
        }
        guard counts != dedupRunCounts else { return }
        dedupRunCounts = counts
    }

    var orderedSelectedRecordIDs: [RecordID] {
        allSelectedRecordIDs ?? selection.orderedSelectedIDs
    }

    var hasAnySelectedRecords: Bool {
        allSelectedRecordIDs?.isEmpty == false || !selection.isEmpty
    }

    func invalidateAllSelectionScope() {
        selectAllWorkItem?.cancel()
        selectAllCancellationToken?.cancel()
        selectAllWorkItem = nil
        selectAllCancellationToken = nil
        selectAllGeneration &+= 1
        allSelectedRecordIDs = nil
        allSelectedRecordIDSet = nil
    }

    func clearSelectionState() {
        invalidateAllSelectionScope()
        selection = MacClippyDockSelectionState()
    }

    // P1: rebind the selection to the current visible-items list, dropping any
    // selected ID that is no longer present and clamping focus/anchor. A Cmd+A
    // scope is special: its complete ID list lives outside the visible state,
    // so only the rendered subset is rebound here and the off-screen IDs stay
    // available to batch actions.
    func rebindSelection() {
        guard selectedTab != .snippets else {
            selection = MacClippyDockSelectionState()
            return
        }
        let ordered = visibleItems.map(\.id)
        if let allSelectedRecordIDSet {
            let visibleSelected = Set(ordered).intersection(allSelectedRecordIDSet)
            let visibleState = MacClippyDockSelectionState(
                orderedIDs: ordered,
                selectedIDs: visibleSelected,
                focusedIndex: selection.focusedIndex,
                anchorIndex: selection.anchorIndex
            )
            selection = MacClippyDockSelectionPolicy.rebinding(visibleState, to: ordered)
        } else {
            selection = MacClippyDockSelectionPolicy.rebinding(selection, to: ordered)
        }
        if selection.focusedIndex != focusedIndex {
            focusedIndex = selection.focusedIndex
        }
    }

    // P1 selection mutations. Each method applies the pure policy and then
    // syncs the model's focusedIndex from the resulting state so the keyboard
    // cursor and the selection focus stay consistent. On the snippets tab the
    // selection is never active and these are no-ops.

    func focusSelection(at index: Int) {
        guard selectedTab != .snippets else {
            focusedIndex = index
            return
        }
        invalidateAllSelectionScope()
        rebindSelection()
        selection = MacClippyDockSelectionPolicy.focusing(selection, at: index)
        focusedIndex = selection.focusedIndex
    }

    func toggleSelection(at index: Int) {
        guard selectedTab != .snippets else { return }
        invalidateAllSelectionScope()
        rebindSelection()
        selection = MacClippyDockSelectionPolicy.toggling(selection, at: index)
        focusedIndex = selection.focusedIndex
    }

    func extendRange(to index: Int) {
        guard selectedTab != .snippets else { return }
        invalidateAllSelectionScope()
        rebindSelection()
        selection = MacClippyDockSelectionPolicy.extendingRange(selection, to: index)
        focusedIndex = selection.focusedIndex
    }

    func extendRangeByStep(_ direction: MacClippyDockSelectionDirection) {
        guard selectedTab != .snippets else { return }
        invalidateAllSelectionScope()
        rebindSelection()
        selection = MacClippyDockSelectionPolicy.extendingRangeByStep(selection, direction: direction)
        focusedIndex = selection.focusedIndex
        requestFocusFollow()
    }

    func moveFocus(_ direction: MacClippyDockSelectionDirection) {
        guard currentCount > 0 else { return }
        if selectedTab == .snippets {
            let offset = direction == .left ? -1 : 1
            focusedIndex = (focusedIndex + offset + currentCount) % currentCount
            requestFocusFollow()
            return
        }
        invalidateAllSelectionScope()
        rebindSelection()
        selection = MacClippyDockSelectionPolicy.movingFocus(selection, direction: direction)
        focusedIndex = selection.focusedIndex
        requestFocusFollow()
    }

    func requestFocusFollow() {
        focusFollowTargetID = selectedTab == .snippets ? focusedSnippet?.id : focusedItem?.id
        focusFollowRequestID &+= 1
    }

    func selectAllVisible() {
        guard selectedTab != .snippets else { return }
        invalidateAllSelectionScope()
        rebindSelection()
        selection = MacClippyDockSelectionPolicy.selectingAll(selection)
        focusedIndex = selection.focusedIndex

        startSelectAllRequest()
    }

    func clearSelection() {
        guard selectedTab != .snippets else { return }
        invalidateAllSelectionScope()
        rebindSelection()
        selection = MacClippyDockSelectionPolicy.clearingSelection(selection)
        focusedIndex = selection.focusedIndex
    }

    func isSelected(_ id: RecordID) -> Bool {
        selectedTab != .snippets && (selection.contains(id) || allSelectedRecordIDSet?.contains(id) == true)
    }

    /// P1 session generation. Bumped by the dock controller on show/hide so a
    /// stale async batch completion from a previous dock session cannot mutate
    /// state or close a newly reopened dock.
    func cancelQueuedPaste() {
        queuePasteCancellationToken?.cancel()
        queuePasteCancellationToken = nil
    }

    /// Every user action supersedes a queued multi-paste. The operation
    /// generation also suppresses stale completion feedback from the action it
    /// replaced.
    @discardableResult
    func beginUserOperation() -> UInt {
        cancelQueuedPaste()
        sideEffectGate?.close()
        sideEffectGate = nil
        operationGeneration &+= 1
        isSelecting = false
        return operationGeneration
    }

    func beginSession() {
        beginUserOperation()
        invalidateAllSelectionScope()
        sessionGeneration &+= 1
        nameOperationGeneration &+= 1
        isSelecting = false
        query = ""
        isSessionActive = true
        focusedIndex = 0
        selection = MacClippyDockSelectionState()
        hasCompletedInitialPaint = false
    }

    func endSession() {
        beginUserOperation()
        invalidateAllSelectionScope()
        historyLoadWorkItem?.cancel()
        historyLoadCancellationToken?.cancel()
        historyLoadWorkItem = nil
        historyLoadCancellationToken = nil
        historyIsLoadingMore = false
        sessionGeneration &+= 1
        isSessionActive = false
        nameOperationGeneration &+= 1
        isSelecting = false
        clearActionFeedback()
        thumbnailLoader.resetForSessionEnd()
    }
}
