import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import SwiftUI

extension MacClippyDockModel {
    // P1 batch actions. Each one captures the session and operation generation
    // at start and verifies both on completion, so a stale completion from a
    // previous dock session or a superseded batch cannot mutate state or close
    // a newly reopened dock. All batch actions act only on the selected record
    // IDs and never inspect or filter their content (no-filter semantics).

    func pasteSelectedAll(completion: @escaping @MainActor @Sendable () -> Void) {
        guard selectedTab != .snippets, hasMultipleSelection else {
            pasteFocused(completion: completion)
            return
        }
        let orderedIDs = orderedSelectedRecordIDs
        guard !orderedIDs.isEmpty else { return }

        beginUserOperation()
        let opGeneration = operationGeneration
        let session = sessionGeneration
        let runtime = runtime
        let sideEffectGate = MacClippyPasteInjectionGate()
        self.sideEffectGate = sideEffectGate
        clearActionError()

        workQueue.async { [weak self, runtime, sideEffectGate] in
            let result = Result {
                try runtime.pasteOrdered(ids: orderedIDs, sideEffectGate: sideEffectGate)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == opGeneration else { return }
                switch result {
                case let .success(pasteResult):
                    switch pasteResult {
                    case let .merged(injected):
                        self.showActionFeedback(.pasted(manual: !injected))
                        completion()
                    case let .mixed(supportedIDs, unsupportedIDs, unsupportedKinds):
                        // Never paste a subset of a mixed selection. Show
                        // transient feedback naming the unsupported kinds so
                        // the user knows exactly what was not pasted.
                        self.showActionFeedback(.multiPasteMixed(
                            supportedCount: supportedIDs.count,
                            unsupportedCount: unsupportedIDs.count,
                            unsupportedKinds: unsupportedKinds
                        ))
                    case let .textUnavailable(availableIDs, unavailableIDs, unavailableKinds):
                        // Never paste when a text-compatible payload was
                        // unavailable/undecodable; merging it as an empty
                        // piece would be silent data loss. Name the
                        // unavailable kinds so the user knows exactly which
                        // records could not be pasted.
                        self.showActionFeedback(.multiPasteUnavailable(
                            availableCount: availableIDs.count,
                            unavailableCount: unavailableIDs.count,
                            unavailableKinds: unavailableKinds
                        ))
                    }
                case .failure:
                    self.setActionError(MacClippyUserFacingError.genericAction)
                }
            }
        }
    }

    func copySelectedAll() {
        guard selectedTab != .snippets, hasMultipleSelection else {
            copyFocused()
            return
        }
        let orderedIDs = orderedSelectedRecordIDs
        guard !orderedIDs.isEmpty else { return }

        beginUserOperation()
        let opGeneration = operationGeneration
        let session = sessionGeneration
        let runtime = runtime
        let sideEffectGate = MacClippyPasteInjectionGate()
        self.sideEffectGate = sideEffectGate
        clearActionError()

        // Copy all prepares the merged homogeneous text on the pasteboard
        // WITHOUT injecting a paste keystroke, mirroring the paste-all merge
        // so a subsequent paste in any app produces the same concatenated
        // text. Mixed/unavailable selections report the unsupported/undecodable
        // kinds; nothing is silently dropped and no subset is prepared.
        workQueue.async { [weak self, runtime, sideEffectGate] in
            let resolution = Result {
                try runtime.copyOrdered(ids: orderedIDs, sideEffectGate: sideEffectGate)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == opGeneration else { return }
                switch resolution {
                case let .success(.merged(prepared)):
                    // prepared is the pasteboard write result; Copy all does
                    // not post a paste keystroke, so prepared is the only
                    // success signal. Show copied feedback either way (a
                    // failed write would have thrown before reaching here).
                    _ = prepared
                    self.showActionFeedback(.copied(plain: false))
                case let .success(.mixed(supportedIDs, unsupportedIDs, unsupportedKinds)):
                    self.showActionFeedback(.multiPasteMixed(
                        supportedCount: supportedIDs.count,
                        unsupportedCount: unsupportedIDs.count,
                        unsupportedKinds: unsupportedKinds
                    ))
                case let .success(.textUnavailable(availableIDs, unavailableIDs, unavailableKinds)):
                    self.showActionFeedback(.multiPasteUnavailable(
                        availableCount: availableIDs.count,
                        unavailableCount: unavailableIDs.count,
                        unavailableKinds: unavailableKinds
                    ))
                case .failure:
                    self.setActionError(MacClippyUserFacingError.genericAction)
                }
            }
        }
    }

}
