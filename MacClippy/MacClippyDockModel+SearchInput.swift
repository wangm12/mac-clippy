import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import QuartzCore
import QuickLookUI
import SwiftUI
import os.signpost

extension MacClippyDockModel {
    func requestSearchFocus() {
        searchFocusIsRequested = true
        searchFocusRequest &+= 1
        applyEmptyOverwriteEvent(.programmaticQueryWrite)
    }

    func resetSearchFocus() {
        searchFocusIsRequested = false
        searchFocusReset &+= 1
    }

    func markSearchFieldEditable() {
        applyEmptyOverwriteEvent(.userKeyEvent)
    }

    func noteSearchFieldUserKeyEvent() {
        applyEmptyOverwriteEvent(.userKeyEvent)
    }

    func commitSearchFieldText(_ incoming: String, hasMarkedText: Bool = false) {
        let current = query
        query = MacClippyDockSearchQueryWritePolicy.committedQuery(
            current: current,
            incoming: incoming,
            allowEmptyOverwrite: allowsEmptySearchFieldOverwrite,
            hasMarkedText: hasMarkedText,
            preservedTokens: Set(searchFilterChips.map(\.token))
        )
        if !incoming.isEmpty, incoming != current {
            applyEmptyOverwriteEvent(.nonEmptyFieldCommit)
        }
    }

    func clearSearchQuery() {
        applyEmptyOverwriteEvent(.explicitClear)
        historySearchClauses = []
        query = ""
        searchQueryProgrammaticWriteToken += 1
    }

    func setErrorForDetails(_ message: String) {
        actionError = message
    }

    func appendSearchText(_ text: String) {
        applyEmptyOverwriteEvent(.programmaticQueryWrite)
        commitSearchFieldText(displayedSearchText + text)
    }

    func deleteSearchCharacter() {
        var text = displayedSearchText
        guard !text.isEmpty else { return }
        applyEmptyOverwriteEvent(.explicitClear)
        text.removeLast()
        commitSearchFieldText(text)
    }

    /// Full-query callers, including the E2E control API, replace conditions
    /// explicitly. Native field commits only edit their visible projection.
    func replaceSearchQuery(_ incoming: String) {
        applyEmptyOverwriteEvent(.programmaticQueryWrite)
        query = incoming
        searchQueryProgrammaticWriteToken += 1
    }

    func applyEmptyOverwriteEvent(_ event: MacClippyDockSearchEmptyOverwriteEvent) {
        allowsEmptySearchFieldOverwrite = MacClippyDockSearchQueryWritePolicy.allowsEmptyOverwrite(
            currently: allowsEmptySearchFieldOverwrite,
            after: event
        )
    }

}
