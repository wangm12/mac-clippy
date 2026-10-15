import Carbon.HIToolbox
import Foundation

import MacClippyCore

extension MacClippySnippetExpander {
    package func scheduleExpansion(_ request: ExpansionRequest) {
        if withLifecycleLock({ usesSyntheticInput }) {
            expansionQueue.async { [weak self] in
                self?.expand(request)
            }
            return
        }

        // The session event tap runs on the main run loop. Hop to its next
        // turn, then do provider and pasteboard work on the serial worker.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.expansionQueue.async { [weak self] in
                self?.expand(request)
            }
        }
    }

    package func expand(_ request: ExpansionRequest) {
        defer { expansionDidFinish() }
        guard isRequestCurrent(request) else {
            restoreSuppressedDelimiterIfSafe(for: request)
            return
        }
        guard let expectedFocusContext = confirmedFocusContext(for: request) else {
            cancelRequest(request)
            restoreSuppressedDelimiterIfSafe(for: request)
            return
        }

        let expandedBody = MacClippySnippetVariablePolicy.expand(
            request.plan.body,
            context: MacClippySnippetVariableContext(clipboard: clipboardTextProvider())
        )
        guard validateRequestFocus(request, expectedContext: expectedFocusContext) else {
            restoreSuppressedDelimiterIfSafe(for: request)
            return
        }

        let result = injector.inject(
            content: .text(expandedBody),
            beforePaste: { [weak self] in
                self?.validateAndCommitTrigger(request) ?? false
            },
            afterPasteEvents: { [weak self] in
                self?.finishCommitAndUnlock(request)
            },
            validateBeforePaste: { [weak self] in
                self?.validateRequestFocus(request, expectedContext: expectedFocusContext) ?? false
            },
            validateCommitContext: { [weak self] in
                self?.validateRequestFocus(request, expectedContext: expectedFocusContext) ?? false
            },
            manualFallback: .preserveClipboard,
            gate: request.gate,
            targetProcessIdentifier: request.focusIdentity.processIdentifier
        )

        switch result {
        case .injected:
            finishRequest(request)
        case .preparedForManualPaste, .failed, .cancelled:
            restoreSuppressedDelimiterIfSafe(for: request)
        }
    }

    private func confirmedFocusContext(for request: ExpansionRequest) -> MacClippySnippetFocusContext? {
        guard let expectedSelection = request.expectedSelection else { return nil }
        // Passing a key through the tap does not mean the recipient has
        // handled it yet. Allow a short delivery window on the worker, while
        // requiring the exact caret and current generation before any delete.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.12
        repeat {
            guard isRequestCurrent(request),
                  let context = focusContext.currentContext(),
                  context.identity == request.focusIdentity,
                  let selection = context.selection else { return nil }
            if selection == expectedSelection { return context }
            guard selection.length == 0,
                  selection.location < expectedSelection.location,
                  ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            Thread.sleep(forTimeInterval: 0.01)
        } while true
    }

    private func validateRequestFocus(
        _ request: ExpansionRequest,
        expectedContext: MacClippySnippetFocusContext
    ) -> Bool {
        guard request.gate.isOpen, isRequestCurrent(request) else { return false }
        guard let freshContext = focusContext.currentContext(),
              freshContext == expectedContext,
              freshContext.selection != nil else {
            cancelRequest(request)
            return false
        }
        return request.gate.isOpen && isRequestCurrent(request)
    }

    private func validateAndCommitTrigger(_ request: ExpansionRequest) -> Bool {
        guard request.gate.isOpen else { return false }
        commitLock.lock()
        lifecycleLock.lock()
        let isCurrent = isRequestGenerationCurrentLocked(request)
            && focusContext.cachedIdentity == request.focusIdentity
        guard isCurrent else {
            if pendingRequest?.identifier == request.identifier {
                pendingRequest = nil
            }
            lifecycleLock.unlock()
            commitLock.unlock()
            return false
        }
        pendingRequest = nil
        committingRequestIdentifier = request.identifier
        committingProcessIdentifier = request.focusIdentity.processIdentifier
        lifecycleLock.unlock()

        let didDeleteTrigger = keyPoster.post(
            keyCodes: Array(repeating: UInt16(kVK_Delete), count: request.plan.charactersToDelete),
            targetProcessIdentifier: request.focusIdentity.processIdentifier
        )
        guard didDeleteTrigger else {
            clearCommitAndUnlock(request)
            return false
        }

        return didDeleteTrigger
    }

    private func clearCommitAndUnlock(_ request: ExpansionRequest) {
        finishCommitAndUnlock(request)
    }

    private func finishCommitAndUnlock(_ request: ExpansionRequest) {
        lifecycleLock.lock()
        guard committingRequestIdentifier == request.identifier else {
            lifecycleLock.unlock()
            return
        }
        committingRequestIdentifier = nil
        committingProcessIdentifier = nil
        let shouldStartReplay = !deferredInputReplayItems.isEmpty && !deferredInputReplayScheduled
        if !deferredInputReplayItems.isEmpty {
            deferredInputReplayActive = true
            if shouldStartReplay {
                deferredInputReplayScheduled = true
            }
        } else {
            deferredInputReplayActive = false
        }
        let shouldFinishStop = stopCleanupPending && !deferredInputReplayActive
        lifecycleLock.unlock()

        commitLock.unlock()
        if shouldStartReplay {
            deferredInputReplayQueue.async {
                self.drainDeferredInputReplay()
            }
        } else if shouldFinishStop {
            finishDeferredStopIfNeeded()
        }
    }

    private func restoreSuppressedDelimiterIfSafe(for request: ExpansionRequest) {
        guard let delimiter = request.plan.suppressedDelimiterKeyCode,
              isRequestGenerationCurrent(request) else {
            finishRequest(request)
            return
        }

        let freshIdentity = focusContext.currentIdentity()
        guard freshIdentity == request.focusIdentity else {
            cancelRequest(request)
            return
        }

        commitLock.lock()
        lifecycleLock.lock()
        let shouldRestore = isRequestGenerationCurrentLocked(request)
            && focusContext.cachedIdentity == request.focusIdentity
            && request.gate.isOpen
        if shouldRestore {
            pendingRequest = nil
        }
        lifecycleLock.unlock()
        if shouldRestore {
            _ = keyPoster.post(
                keyCode: delimiter,
                gate: request.gate,
                targetProcessIdentifier: request.focusIdentity.processIdentifier
            )
        }
        commitLock.unlock()
    }

    private func isRequestCurrent(_ request: ExpansionRequest) -> Bool {
        let cachedIdentity = focusContext.cachedIdentity
        return withLifecycleLock {
            isRequestCurrentLocked(request)
                && cachedIdentity == request.focusIdentity
        }
    }

    private func isRequestCurrentLocked(_ request: ExpansionRequest) -> Bool {
        isRequestGenerationCurrentLocked(request)
            && modeProvider() != .disabled
    }

    private func isRequestGenerationCurrent(_ request: ExpansionRequest) -> Bool {
        withLifecycleLock { isRequestGenerationCurrentLocked(request) }
    }

    private func isRequestGenerationCurrentLocked(_ request: ExpansionRequest) -> Bool {
        installed
            && lifecycleGeneration == request.lifecycleGeneration
            && inputGeneration == request.inputGeneration
            && pendingRequest?.identifier == request.identifier
    }

    private func cancelRequest(_ request: ExpansionRequest) {
        withLifecycleLock {
            if pendingRequest?.identifier == request.identifier {
                pendingRequest = nil
            }
        }
    }

    package func finishRequest(_ request: ExpansionRequest) {
        withLifecycleLock {
            if pendingRequest?.identifier == request.identifier {
                pendingRequest = nil
            }
            if committingRequestIdentifier == request.identifier {
                committingRequestIdentifier = nil
            }
        }
    }
}
