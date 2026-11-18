import Foundation

import MacClippyCore

private enum PendingRetryStep {
    case change(PasteboardChange)
    case disposition(PasteboardPollReadDisposition)
}

extension MacClippyPasteboardObserver {
    func processCatchUp(
        after lastSeen: Int,
        observed: Int,
        generation: UInt64
    ) -> PasteboardPollReadDisposition {
        let counts = MacClippyMissedChangeCountPolicy.catchUpChangeCounts(
            after: lastSeen,
            observed: observed
        )
        for count in counts {
            guard isCurrentLifecycle(generation) else { return .cancelled }
            if consumeInternalWrite(changeCount: count) { continue }
            let outcome = reader.readOutcome(changeCount: count, shouldContinue: { [weak self] in
                self?.isCurrentLifecycle(generation) ?? false
            })
            switch outcome {
            case let .success(change):
                guard change.changeCount == count else { continue }
                clearReadFailureState(for: count)
                processMaterializedChange(
                    change,
                    generation: generation,
                    requireCurrentMatch: count == observed
                )
            case .generationUnavailable:
                markGenerationConsumed(count)
            case .cancelled:
                return .cancelled
            case let .failed(failure):
                guard reader.currentChangeCount() == count else {
                    markGenerationConsumed(count)
                    continue
                }
                return handleReadFailure(failure, changeCount: count)
            }
        }
        return .completed
    }

    func handleReadFailure(
        _ failure: MacClippyPasteboardReadFailure,
        changeCount: Int
    ) -> PasteboardPollReadDisposition {
        guard reader.currentChangeCount() == changeCount else {
            clearReadFailureState(for: changeCount)
            return .completed
        }
        if failedReadChangeCount != changeCount {
            failedReadChangeCount = changeCount
            failedReadAttempts = 0
        }
        failedReadAttempts = min(Self.maximumReadFailureAttempts, failedReadAttempts + 1)
        guard failedReadAttempts >= Self.maximumReadFailureAttempts else { return .retry }

        retryState.clear(changeCount: changeCount)
        lastChangeCount = changeCount
        clearReadFailureState(for: changeCount)
        diagnosticsRecorder.record(MacClippyDiagnosticsEvent(
            category: .capture,
            code: .pasteboardReadFailed,
            operation: "pasteboard_generation_read_failed",
            retryCount: Self.maximumReadFailureAttempts,
            recoveryAction: "generation_abandoned_after_bounded_read_retries",
            impact: failure.operation
        ))
        return .cancelled
    }

    func clearReadFailureState(for changeCount: Int? = nil) {
        guard changeCount == nil || failedReadChangeCount == changeCount else { return }
        failedReadChangeCount = nil
        failedReadAttempts = 0
    }

    func markGenerationConsumed(_ changeCount: Int) {
        retryState.clear(changeCount: changeCount)
        clearReadFailureState(for: changeCount)
        if lastChangeCount.map({ changeCount > $0 }) ?? true {
            lastChangeCount = changeCount
        }
    }

    func consumeInternalWrite(changeCount: Int) -> Bool {
        guard let writeSentinel, writeSentinel.consume(changeCount: changeCount) else {
            return false
        }
        retryState.clear(changeCount: changeCount)
        clearReadFailureState(for: changeCount)
        lastChangeCount = changeCount
        recoverySuppressedChangeCount = changeCount
        return true
    }

    func processPendingRetry(
        _ pending: MacClippyPasteboardReadRetryState.Pending,
        generation: UInt64
    ) -> PasteboardPollReadDisposition {
        let change: PasteboardChange
        switch readPendingRetrySource(pending, generation: generation) {
        case let .change(value):
            change = value
        case let .disposition(disposition):
            return disposition
        }
        let reread: PasteboardChange
        switch rereadPendingRetry(change, pending: pending, generation: generation) {
        case let .change(value):
            reread = value
        case let .disposition(disposition):
            return disposition
        }
        return finishPendingRetry(reread, generation: generation)
    }

    private func readPendingRetrySource(
        _ pending: MacClippyPasteboardReadRetryState.Pending,
        generation: UInt64
    ) -> PendingRetryStep {
        if let originalChange = pending.originalChange {
            return .change(originalChange)
        }
        let outcome = reader.readOutcome(shouldContinue: { [weak self] in
            self?.isCurrentLifecycle(generation) ?? false
        })
        switch outcome {
        case let .success(change):
            guard change.changeCount == pending.changeCount,
                  reader.currentChangeCount() == pending.changeCount else {
                retryState.clear(changeCount: pending.changeCount)
                return .disposition(.completed)
            }
            return .change(change)
        case let .failed(failure):
            return .disposition(handleReadFailure(failure, changeCount: pending.changeCount))
        case .cancelled:
            return .disposition(.cancelled)
        case .generationUnavailable:
            retryState.clear(changeCount: pending.changeCount)
            return .disposition(.completed)
        }
    }

    private func rereadPendingRetry(
        _ change: PasteboardChange,
        pending: MacClippyPasteboardReadRetryState.Pending,
        generation: UInt64
    ) -> PendingRetryStep {
        guard isCurrentLifecycle(generation) else { return .disposition(.cancelled) }
        let outcome = reader.rereadOutcome(
            change: change,
            unavailableTypes: pending.unavailableTypes,
            shouldContinue: { [weak self] in self?.isCurrentLifecycle(generation) ?? false }
        )
        switch outcome {
        case let .success(updated):
            clearReadFailureState(for: change.changeCount)
            return .change(updated)
        case let .failed(failure):
            return .disposition(handleReadFailure(failure, changeCount: change.changeCount))
        case .cancelled:
            return .disposition(.cancelled)
        case .generationUnavailable:
            retryState.clear(changeCount: change.changeCount)
            clearReadFailureState(for: change.changeCount)
            return .disposition(.completed)
        }
    }

    private func finishPendingRetry(
        _ reread: PasteboardChange,
        generation: UInt64
    ) -> PasteboardPollReadDisposition {
        let changeCount = reread.changeCount
        guard isCurrentLifecycle(generation) else { return .cancelled }
        guard reader.currentChangeCount() == changeCount else {
            // The provider reread crossed a new pasteboard generation. Never
            // deliver bytes from the old generation.
            retryState.clear(changeCount: changeCount)
            clearReadFailureState(for: changeCount)
            return .completed
        }
        let stillUnavailable = MacClippyPasteboardAvailability.unavailableTypes(in: reread)
        guard !stillUnavailable.isEmpty else {
            retryState.clear(changeCount: changeCount)
            deliver(reread, changeCount: changeCount)
            return .completed
        }
        guard retryState.update(change: reread, unavailableTypes: stillUnavailable) else {
            // Item/type identity changed without a generation transition.
            // Discard the partial retry and force a fresh full read next poll.
            retryState.clear(changeCount: changeCount)
            return .completed
        }
        guard !retryState.incrementAttempts(for: changeCount) else { return .completed }
        retryState.clear(changeCount: changeCount)
        deliver(reread, changeCount: changeCount)
        return .completed
    }

    func processFreshChange(
        changeCount: Int,
        generation: UInt64
    ) -> PasteboardPollReadDisposition {
        // The generation changed, so pay the cost of materializing all
        // advertised representations exactly once for this poll.
        let outcome = reader.readOutcome(shouldContinue: { [weak self] in
            self?.isCurrentLifecycle(generation) ?? false
        })
        guard isCurrentLifecycle(generation) else { return .cancelled }
        let change: PasteboardChange
        switch outcome {
        case let .success(readChange):
            change = readChange
            clearReadFailureState(for: readChange.changeCount)
        case let .failed(failure):
            return handleReadFailure(failure, changeCount: changeCount)
        case .cancelled:
            return .cancelled
        case .generationUnavailable:
            clearReadFailureState()
            return .completed
        }
        processMaterializedChange(change, generation: generation, requireCurrentMatch: true)
        return .completed
    }

    func processMaterializedChange(
        _ change: PasteboardChange,
        generation: UInt64,
        requireCurrentMatch: Bool
    ) {
        let changeCount = change.changeCount
        guard lastChangeCount != changeCount else { return }
        if requireCurrentMatch {
            guard reader.currentChangeCount() == changeCount else {
                // A pasteboard write raced materialization. The next poll reads
                // the current generation from scratch.
                return
            }
        }
        guard isCurrentLifecycle(generation) else { return }

        let unavailable = MacClippyPasteboardAvailability.unavailableTypes(in: change)
        guard !unavailable.isEmpty else {
            deliver(change, changeCount: changeCount)
            return
        }

        // Spend the first attempt. If the budget is already exhausted, retain
        // the advertised type as an unavailable marker immediately.
        retryState.record(change: change, unavailableTypes: unavailable)
        guard !retryState.incrementAttempts(for: changeCount) else { return }
        retryState.clear(changeCount: changeCount)
        deliver(change, changeCount: changeCount)
    }

    func deliver(_ change: PasteboardChange, changeCount: Int) {
        guard isLifecycleStarted() else { return }
        clearReadFailureState(for: changeCount)
        lastChangeCount = changeCount
        noteObservedChangeOnLifecycleQueue()
        let ignore = MacClippyCapturePausePolicy.consumeIgnoreNext(ignoreNextCopyCount)
        ignoreNextCopyCount = ignore.remaining
        if ignore.shouldIgnore { publishCaptureStatus() }
        guard !ignore.shouldIgnore else {
            recoverySuppressedChangeCount = changeCount
            return
        }
        // Drop any retry state for older changeCounts; they can never be
        // observed again because changeCount is monotonic per pasteboard.
        for pendingChangeCount in retryState.stalePendingChangeCounts(below: changeCount) {
            retryState.clear(changeCount: pendingChangeCount)
        }
        let rules = exclusionRules
        guard !change.items.isEmpty,
              !rules.shouldExclude(
                  appBundleID: change.sourceAppBundleID,
                  pasteboardTypes: change.pasteboardTypes
              ) else { return }

        if let admissionHandler, let admittedProjectionHandler {
            // Reserve capacity before mapping can allocate the primary payload
            // or searchable text. Privacy inspects all retained text under one
            // generation budget, independently of payload priority.
            guard let admission = admissionHandler(change) else { return }
            guard !MacClippyPasteboardPrivacyTextFilter.shouldExclude(change, rules: rules) else { return }
            let projection = MacClippyCaptureMapper.projection(for: change)
            admittedProjectionHandler(change, projection, admission)
            return
        }

        guard !MacClippyPasteboardPrivacyTextFilter.shouldExclude(change, rules: rules) else { return }
        let projection = MacClippyCaptureMapper.projection(for: change)
        projectionHandler?(change, projection)
    }

    func recordMissedChangeCountsIfNeeded(observedChangeCount: Int) {
        guard let lastChangeCount,
              observedChangeCount > lastChangeCount + 1 else {
            return
        }
        diagnosticsRecorder.record(
            MacClippyDiagnosticsEvent(
                category: .capture,
                code: .missedChangeCounts,
                operation: "pasteboard_missed_change_counts",
                recoveryAction: MacClippyMissedChangeCountPolicy.recoveryAction,
                impact: "pasteboard_generation_gap"
            )
        )
    }
}
