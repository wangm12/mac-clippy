import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import SwiftUI

private enum MacClippyDockOperationError: Error {
    case returnedFailure
}

extension MacClippyDockModel {
    func select(
        _ item: MacClippyHistoryEntry,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        guard !isSelecting else { return }
        let runtimeReference = runtime
        let operation = beginUserOperation()
        let session = sessionGeneration
        let sideEffectGate = MacClippyPasteInjectionGate()
        self.sideEffectGate = sideEffectGate
        isSelecting = true
        clearActionError()

        workQueue.async { [weak self, runtimeReference, sideEffectGate] in
            let result = Result {
                try runtimeReference.paste(id: item.id, sideEffectGate: sideEffectGate)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == operation else { return }
                self.isSelecting = false
                switch result {
                case let .success(pasteResult):
                    self.showActionFeedback(.pasted(manual: pasteResult == .manualPasteRequired))
                    completion()
                case .failure:
                    self.setActionError(MacClippyUserFacingError.genericAction)
                }
            }
        }
    }

    func select(
        _ snippet: MacClippySnippetEntry,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        guard !isSelecting else { return }
        let runtimeReference = runtime
        let operation = beginUserOperation()
        let session = sessionGeneration
        let sideEffectGate = MacClippyPasteInjectionGate()
        self.sideEffectGate = sideEffectGate
        isSelecting = true
        clearActionError()

        workQueue.async { [weak self, runtimeReference, sideEffectGate] in
            let result = Result {
                try runtimeReference.paste(snippetID: snippet.id, sideEffectGate: sideEffectGate)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == operation else { return }
                self.isSelecting = false
                switch result {
                case let .success(pasteResult):
                    self.showActionFeedback(.pasted(manual: pasteResult == .manualPasteRequired))
                    completion()
                case .failure:
                    self.setActionError(MacClippyUserFacingError.genericAction)
                }
            }
        }
    }

    var currentCount: Int {
        selectedTab == .snippets ? visibleSnippets.count : visibleItems.count
    }

    func reconcileSelectedTab() {
        if case let .pinboard(id) = selectedTab,
           !pinboards.contains(where: { $0.id == id }) {
            selectedTab = .history
        }
    }

    func filter(_ items: [MacClippyHistoryEntry], by query: String) -> [MacClippyHistoryEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, selectedTab != .history else { return items }
        // P2b: apply the structured search grammar to pinboard-tab filtering
        // so a query like type:image or name:work narrows a pinboard the
        // same way it narrows history. The history tab is unaffected here
        // because its results already come from runtime.history (which
        // applies the same grammar), so the dock never re-filters history.
        let parsed = MacClippySearchGrammar.parse(normalizedQuery)
        // No structured clauses: preserve the existing local substring filter
        // on the raw query so bare-term pinboard search behavior is
        // unchanged.
        guard parsed.hasStructuredClauses else {
            return items.filter { $0.preview.localizedCaseInsensitiveContains(normalizedQuery) }
        }
        return items.filter { entry in
            let record = MacClippySearchGrammar.SearchRecord(
                contentKind: entry.contentKind,
                sourceAppBundleID: entry.meta.sourceAppBundleID,
                customLabel: entry.meta.customLabel,
                ocrText: entry.meta.ocrText,
                modified: entry.meta.modified
            )
            guard MacClippySearchGrammar.matches(parsed, record: record) else { return false }
            // AND with the existing bare-term substring on the preview so a
            // mixed query (e.g. important type:text) still narrows by the
            // bare portion too. With no bare terms, only the structured
            // predicate applies.
            if parsed.bareTerms.isEmpty { return true }
            let bare = parsed.bareTerms.joined(separator: " ")
            return entry.preview.localizedCaseInsensitiveContains(bare)
        }
    }

    func perform(
        _ operation: @escaping @Sendable () throws -> Bool,
        onSuccess: (@MainActor @Sendable () -> Void)? = nil,
        onFailure: (@MainActor @Sendable () -> Void)? = nil
    ) {
        clearActionError()
        let userOperation = beginUserOperation()
        let session = sessionGeneration
        workQueue.async { [weak self] in
            let result = Result {
                guard try operation() else {
                    throw MacClippyDockOperationError.returnedFailure
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == userOperation else { return }
                switch result {
                case .success:
                    onSuccess?()
                case .failure:
                    self.setActionError(MacClippyUserFacingError.genericAction)
                    onFailure?()
                }
            }
        }
    }

    func performWithSideEffect(
        _ operation: @escaping @Sendable (MacClippyPasteInjectionGate) throws -> Bool,
        onSuccess: (@MainActor @Sendable () -> Void)? = nil,
        onFailure: (@MainActor @Sendable () -> Void)? = nil
    ) {
        clearActionError()
        let userOperation = beginUserOperation()
        let session = sessionGeneration
        let gate = MacClippyPasteInjectionGate()
        sideEffectGate = gate
        workQueue.async { [weak self, gate] in
            let result = Result {
                guard try operation(gate) else {
                    throw MacClippyDockOperationError.returnedFailure
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == userOperation else { return }
                switch result {
                case .success:
                    onSuccess?()
                case .failure:
                    self.setActionError(MacClippyUserFacingError.genericAction)
                    onFailure?()
                }
            }
        }
    }

    func clearActionFeedback() {
        actionFeedbackTask?.cancel()
        actionFeedbackTask = nil
        actionFeedback = nil
    }

    func showActionFeedback(_ feedback: MacClippyDockActionFeedback) {
        actionFeedbackTask?.cancel()
        actionFeedback = feedback
        actionFeedbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(MacClippyMotion.actionFeedbackLifetime * 1_000_000_000))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.actionFeedback = nil
            self.actionFeedbackTask = nil
        }
    }
}
