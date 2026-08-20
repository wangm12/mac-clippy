import Foundation

import MacClippyCore

struct MacClippyDockPinboardVisibleItemsState {
    let query: String
    let boardID: RecordID
    let source: [MacClippyHistoryEntry]
    let searchBoardID: RecordID?
    let searchQuery: String
    let searchItems: [MacClippyHistoryEntry]
    let isLoading: Bool
}

enum MacClippyDockPinboardVisibleItems {
    static func resolve(
        _ state: MacClippyDockPinboardVisibleItemsState
    ) -> [MacClippyHistoryEntry] {
        if state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return state.source
        }
        guard state.searchBoardID == state.boardID else { return state.source }
        if !state.searchItems.isEmpty { return state.searchItems }
        if state.isLoading || state.searchQuery != state.query { return state.source }
        return state.searchItems
    }
}
