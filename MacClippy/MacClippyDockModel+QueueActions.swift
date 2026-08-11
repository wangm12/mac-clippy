import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import SwiftUI

extension MacClippyDockModel {
    /// Mixed-content sequential queue paste for the current ordered multi-
    /// selection. Processes the selected IDs one at a time in visual order,
    /// injecting a separate Cmd+V per record so mixed selections (text + image
    /// + files) can each be consumed by the target app. Session/operation
    /// generation guards match pasteSelectedAll so a stale completion from a
    /// previous dock session cannot mutate state or close a newly reopened dock.
    /// A single-selection fallback routes through the existing pasteFocused
    /// path, matching pasteSelectedAll's fallback. Full success (every record
    /// injected, no unavailable and no manual stop) closes the dock through the
    /// existing completion; partial completion (some unavailable) and manual-
    /// paste stop keep the dock open so the explicit result is visible. No
    /// success is reported for skipped or unconsumed IDs.
    func pasteQueued(completion: @escaping @MainActor @Sendable () -> Void) {
        guard selectedTab != .snippets, hasMultipleSelection else {
            pasteFocused(completion: completion)
            return
        }
        let orderedIDs = orderedSelectedRecordIDs
        guard !orderedIDs.isEmpty else { return }

        beginUserOperation()
        let cancellationToken = MacClippyCancellationToken()
        queuePasteCancellationToken = cancellationToken
        let opGeneration = operationGeneration
        let session = sessionGeneration
        let runtime = runtime
        let sideEffectGate = MacClippyPasteInjectionGate()
        self.sideEffectGate = sideEffectGate
        clearActionError()

        workQueue.async { [weak self, runtime, cancellationToken, sideEffectGate] in
            let result = Result {
                try runtime.pasteQueued(
                    ids: orderedIDs,
                    shouldCancel: { cancellationToken.isCancelled },
                    sideEffectGate: sideEffectGate
                )
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishQueuedPaste(
                    result: result,
                    session: session,
                    operation: opGeneration,
                    cancellationToken: cancellationToken,
                    completion: completion
                )
            }
        }
    }

    private func finishQueuedPaste(
        result: Result<MacClippyQueuePasteResult, Error>,
        session: UInt,
        operation: UInt,
        cancellationToken: MacClippyCancellationToken,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        guard sessionGeneration == session else { return }
        if queuePasteCancellationToken === cancellationToken {
            queuePasteCancellationToken = nil
        }
        guard operationGeneration == operation else { return }

        switch result {
        case let .success(queueResult):
            switch queueResult {
            case let .completed(injectedIDs, unavailableIDs, unavailableKinds):
                if unavailableIDs.isEmpty {
                    showActionFeedback(.queuePasteCompleted(
                        injectedCount: injectedIDs.count,
                        unavailableCount: 0
                    ))
                    completion()
                } else {
                    showActionFeedback(.queuePastePartial(
                        injectedCount: injectedIDs.count,
                        unavailableCount: unavailableIDs.count,
                        unavailableKinds: unavailableKinds
                    ))
                }
            case let .manualPasteRequired(
                injectedIDs,
                unavailableIDs,
                unavailableKinds,
                manualPasteRequiredID,
                remainingIDs
            ):
                _ = unavailableIDs
                _ = unavailableKinds
                _ = manualPasteRequiredID
                showActionFeedback(.queuePasteManualStop(
                    injectedCount: injectedIDs.count,
                    remainingCount: remainingIDs.count
                ))
            }
        case .failure:
            setActionError(MacClippyUserFacingError.genericAction)
        }
    }

    func deleteSelected() {
        guard selectedTab != .snippets, hasAnySelectedRecords else {
            deleteFocused()
            return
        }
        let orderedIDs = orderedSelectedRecordIDs
        guard !orderedIDs.isEmpty else { return }

        beginUserOperation()
        let opGeneration = operationGeneration
        let session = sessionGeneration
        let runtime = runtime
        clearActionError()

        workQueue.async { [weak self, runtime] in
            let result = Result { try runtime.delete(ids: orderedIDs) }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == opGeneration else { return }
                switch result {
                case let .success(batchResult):
                    // A complete success requires both no missing IDs and no
                    // per-item failures; otherwise report a partial result so
                    // a failing item can never silently make the UI report a
                    // complete batch. Reload always so the list reflects the
                    // partial deletion instead of going stale.
                    if batchResult.missingIDs.isEmpty, batchResult.failedIDs.isEmpty {
                        self.showActionFeedback(.deleted)
                    } else {
                        let succeeded = batchResult.deletedIDs.count
                        let unsupported = batchResult.missingIDs.count + batchResult.failedIDs.count
                        self.showActionFeedback(.batchPartial(
                            succeeded: succeeded,
                            unsupported: unsupported
                        ))
                    }
                    self.clearSelectionState()
                    self.reload()
                case .failure:
                    self.setActionError(MacClippyUserFacingError.genericAction)
                }
            }
        }
    }

    func pinSelected() {
        guard selectedTab != .snippets, hasAnySelectedRecords,
              let target = batchPinTarget
        else {
            return
        }
        let orderedIDs = orderedSelectedRecordIDs
        guard !orderedIDs.isEmpty else { return }

        beginUserOperation()
        let opGeneration = operationGeneration
        let session = sessionGeneration
        let runtime = runtime
        clearActionError()

        workQueue.async { [weak self, runtime] in
            let result = Result { try runtime.pin(recordIDs: orderedIDs, to: target.id) }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == opGeneration else { return }
                switch result {
                case let .success(batchResult):
                    // A complete success requires both no missing IDs and no
                    // per-item failures; otherwise report a partial result so
                    // a failing item can never silently make the UI report a
                    // complete batch. Clear selection and reload always so the
                    // board reflects the partial pin instead of going stale.
                    if batchResult.missingIDs.isEmpty, batchResult.failedIDs.isEmpty {
                        self.showActionFeedback(.pinnedTo(boardName: batchResult.boardName))
                    } else {
                        let succeeded = batchResult.pinnedIDs.count
                        let unsupported = batchResult.missingIDs.count + batchResult.failedIDs.count
                        self.showActionFeedback(.batchPartial(
                            succeeded: succeeded,
                            unsupported: unsupported
                        ))
                    }
                    self.clearSelection()
                    self.reload()
                case .failure:
                    self.setActionError(MacClippyUserFacingError.genericAction)
                }
            }
        }
    }
}
