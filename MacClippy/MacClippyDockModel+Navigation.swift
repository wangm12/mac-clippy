import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import SwiftUI

extension MacClippyDockModel {
    func presentCreateCategory() {
        modalPresentationToken &+= 1
        modal = .createCategory(token: modalPresentationToken)
    }

    func presentRenameItem(for entry: MacClippyHistoryEntry) {
        modalPresentationToken &+= 1
        modal = .renameItem(recordID: entry.id, initialName: entry.customLabel, token: modalPresentationToken)
    }

    func presentRenameCategory(for pinboard: MacClippyPinboardEntry) {
        modalPresentationToken &+= 1
        modal = .renameCategory(pinboardID: pinboard.id, token: modalPresentationToken)
    }

    func presentConfirmDeleteCategory(for pinboard: MacClippyPinboardEntry) {
        modalPresentationToken &+= 1
        modal = .confirmDeleteCategory(
            pinboardID: pinboard.id, name: pinboard.name, token: modalPresentationToken)
    }

    func dismissModal() {
        modal = nil
        isFilterPopoverPresented = false
    }

    func removeSearchFilter(token: String) {
        query = MacClippySearchFilterChipPolicy.removing(token: token, from: query)
    }

    func appendSearchFilter(token: String) {
        query = MacClippySearchFilterChipPolicy.appending(token: token, to: query)
    }

    func toggleSmartList(_ list: MacClippySmartList) {
        applyEmptyOverwriteEvent(.programmaticQueryWrite)
        if selectedTab != .history {
            selectTab(.history)
        }
        let replacement =
            MacClippySmartListPolicy.isActive(list, in: query)
            ? nil : MacClippySearchGrammar.parse(list.query).clauses.first
        query = MacClippySearchWorkflowPolicy.replacing(.contentType, with: replacement, in: query)
        searchQueryProgrammaticWriteToken += 1
    }

    func selectAllFilter() {
        if selectedTab != .history {
            selectTab(.history)
        }
        if historyQuery != query { reload(includeStaticData: false) }
    }

    func selectSnippetsFilter() {
        if selectedTab != .snippets {
            selectTab(.snippets)
        }
        scheduleSnippetFilter()
    }

    /// User clicks toggle a category; programmatic selection stays idempotent.
    func toggleTabFilter(_ tab: MacClippyDockTab) {
        if tab == .history || selectedTab == tab {
            selectAllFilter()
        } else if tab == .snippets {
            selectSnippetsFilter()
        } else {
            selectTab(tab)
        }
    }

    func hideSmartList(_ list: MacClippySmartList) {
        if MacClippySmartListPolicy.isActive(list, in: query) {
            query = MacClippySmartListPolicy.apply(list, to: query)
        }
        hiddenSmartListIDs = MacClippySmartListPolicy.hiding(list, in: hiddenSmartListIDs)
        MacClippySmartListPolicy.persist(hiddenIDs: hiddenSmartListIDs, to: defaults)
    }

}
