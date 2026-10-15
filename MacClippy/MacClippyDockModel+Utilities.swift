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
        plain: Bool? = nil,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        selectRecord(id: item.id, plain: plain, completion: completion)
    }

    func selectRecord(
        id: RecordID,
        plain: Bool? = nil,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        guard !isSelecting else { return }
        let runtimeReference = runtime
        let targetPID = pasteTargetProcessIdentifier
        let operation = beginUserOperation()
        let session = sessionGeneration
        let sideEffectGate = MacClippyPasteInjectionGate()
        self.sideEffectGate = sideEffectGate
        isSelecting = true
        clearActionError()
        let pastePlain = plain ?? MacClippyRetentionPreferences.shouldPastePlain(
            shiftHeld: false,
            defaults: defaults
        )

        workQueue.async { [weak self, runtimeReference, sideEffectGate] in
            let result = Result {
                try runtimeReference.paste(
                    id: id, plain: pastePlain, targetProcessIdentifier: targetPID, sideEffectGate: sideEffectGate)
            }
            MacClippyMainHop.async { [weak self] in
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == operation else { return }
                self.isSelecting = false
                switch result {
                case let .success(pasteResult):
                    switch pasteResult {
                    case .injected:
                        self.showActionFeedback(.pasted(manual: false))
                        completion()
                    case .preparedForManualPaste:
                        self.showActionFeedback(.pasted(manual: true))
                        completion()
                    case let .failed(failure):
                        self.setActionError(failure.localizedDescription)
                    case .cancelled:
                        break
                    }
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
        selectSnippet(id: snippet.id, completion: completion)
    }

    func selectSnippet(id: RecordID, completion: @escaping @MainActor @Sendable () -> Void) {
        guard !isSelecting else { return }
        let runtimeReference = runtime
        let targetPID = pasteTargetProcessIdentifier
        let operation = beginUserOperation()
        let session = sessionGeneration
        let sideEffectGate = MacClippyPasteInjectionGate()
        self.sideEffectGate = sideEffectGate
        isSelecting = true
        clearActionError()

        workQueue.async { [weak self, runtimeReference, sideEffectGate] in
            let result = Result {
                try runtimeReference.paste(
                    snippetID: id, manualFallback: .prepareClipboard,
                    targetProcessIdentifier: targetPID, sideEffectGate: sideEffectGate)
            }
            MacClippyMainHop.async { [weak self] in
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == operation else { return }
                self.isSelecting = false
                switch result {
                case let .success(pasteResult):
                    switch pasteResult {
                    case .injected:
                        self.showActionFeedback(.pasted(manual: false))
                        completion()
                    case .preparedForManualPaste:
                        self.showActionFeedback(.pasted(manual: true))
                        completion()
                    case let .failed(failure):
                        self.setActionError(failure.localizedDescription)
                    case .cancelled:
                        break
                    }
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
        #if DEBUG
        visibleItemsFilterCount += 1
        #endif
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return items }
        // Apply the structured search grammar locally so a typed query still
        // narrows the last snapshot while a history reload is in flight.
        let parsed = MacClippySearchGrammar.parse(normalizedQuery)
        // No structured clauses: preserve the existing local substring filter
        // on the raw query so bare-term pinboard search behavior is
        // unchanged.
        guard parsed.hasStructuredClauses else {
            return items.filter { entry in
                MacClippySearchQuery.allTerms(
                    parsed.bareTerms.isEmpty ? [normalizedQuery] : parsed.bareTerms,
                    appearIn: [
                        entry.preview,
                        entry.meta.ocrText ?? "",
                        entry.meta.customLabel ?? ""
                    ]
                )
            }
        }
        return items.filter { entry in
            let record = MacClippySearchGrammar.SearchRecord(
                contentKind: entry.contentKind,
                sourceAppBundleID: entry.meta.sourceAppBundleID,
                sourceAppDisplayName: MacClippySourceAppSearch.preferredDisplayName(
                    stored: entry.meta.sourceAppDisplayName,
                    resolved: MacClippySourceAppResolver.cachedDisplayName(
                        for: entry.meta.sourceAppBundleID
                    )
                ),
                customLabel: entry.meta.customLabel,
                ocrText: entry.meta.ocrText,
                modified: entry.meta.modified,
                isURL: MacClippySearchGrammar.SearchRecord.detectsURL(entry.meta)
            )
            guard MacClippySearchGrammar.matches(parsed, record: record) else { return false }
            if parsed.bareTerms.isEmpty { return true }
            return MacClippySearchQuery.allTerms(
                parsed.bareTerms,
                appearIn: [
                    entry.preview,
                    entry.meta.ocrText ?? "",
                    entry.meta.customLabel ?? ""
                ]
            )
        }
    }

    func perform(
        _ operation: @escaping @Sendable () throws -> Bool,
        onSuccess: (@MainActor @Sendable () -> Void)? = nil,
        onFailure: (@MainActor @Sendable () -> Void)? = nil,
        onStale: (@MainActor @Sendable () -> Void)? = nil
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
            MacClippyMainHop.async { [weak self] in
                guard let self else {
                    onStale?()
                    return
                }
                guard self.sessionGeneration == session,
                      self.operationGeneration == userOperation else {
                    onStale?()
                    return
                }
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
        _ operation: @escaping @Sendable (MacClippyPasteInjectionGate) throws -> Void,
        onSuccess: (@MainActor @Sendable () -> Void)? = nil,
        onFailure: (@MainActor @Sendable () -> Void)? = nil
    ) {
        clearActionError()
        let userOperation = beginUserOperation()
        let session = sessionGeneration
        let gate = MacClippyPasteInjectionGate()
        sideEffectGate = gate
        workQueue.async { [weak self, gate] in
            let result = Result { try operation(gate) }
            MacClippyMainHop.async { [weak self] in
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == userOperation else { return }
                switch result {
                case .success:
                    onSuccess?()
                case let .failure(error):
                    self.setActionError(MacClippyUserFacingError.message(for: error))
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
        if feedback.isScreenToastFeedback { actionToastHandler?(feedback) }
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
