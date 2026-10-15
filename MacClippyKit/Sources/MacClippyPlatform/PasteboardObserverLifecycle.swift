import Foundation

import MacClippyCore

enum PasteboardPollReadDisposition {
    case completed
    case retry
    case cancelled
}

extension MacClippyPasteboardObserver {
    func pollOnLifecycleQueue() {
        let generation = lifecycleGenerationValue()
        guard isCurrentLifecycle(generation), !pollingSuspended else { return }
        refreshPollActivityOnLifecycleQueue()
        let observedChangeCount = reader.currentChangeCount()
        clearStaleReadFailureState(observedChangeCount: observedChangeCount)
        guard !suppressPausedGeneration(observedChangeCount) else { return }
        guard !skipRedundantRecoveryPoll(observedChangeCount, lifecycle: generation) else { return }
        processObservedChangeCount(observedChangeCount, lifecycle: generation)
    }

    private func clearStaleReadFailureState(observedChangeCount: Int) {
        guard failedReadChangeCount != observedChangeCount else { return }
        clearReadFailureState()
    }

    private func suppressPausedGeneration(_ observedChangeCount: Int) -> Bool {
        guard capturePaused else { return false }
        retryState.clear(changeCount: observedChangeCount)
        clearReadFailureState()
        let wasUnseenGeneration = lastChangeCount != observedChangeCount
        lastChangeCount = observedChangeCount
        if wasUnseenGeneration {
            recoverySuppressedChangeCount = observedChangeCount
        }
        return true
    }

    private func skipRedundantRecoveryPoll(_ observedChangeCount: Int, lifecycle: UInt64) -> Bool {
        guard beginRecoveryRead(observedChangeCount: observedChangeCount) else { return false }
        completeRecoveryReadWaiters(
            isCurrentLifecycle(lifecycle) ? (lastChangeCount ?? observedChangeCount) : nil
        )
        return true
    }

    private func processObservedChangeCount(_ observedChangeCount: Int, lifecycle: UInt64) {
        var disposition = PasteboardPollReadDisposition.completed
        defer {
            finishRecoveryRead(disposition, observedChangeCount: observedChangeCount, lifecycle: lifecycle)
        }
        let pendingRetry = retryState.pending(for: observedChangeCount)
        if pendingRetry == nil {
            recordMissedChangeCountsIfNeeded(observedChangeCount: observedChangeCount)
        }
        if let pending = pendingRetry {
            disposition = processPendingRetryOrSkipInternalWrite(
                pending,
                changeCount: observedChangeCount,
                generation: lifecycle
            )
            return
        }
        guard lastChangeCount != observedChangeCount else { return }
        if let lastChangeCount,
           MacClippyMissedChangeCountPolicy.hasMissedGenerations(
            after: lastChangeCount,
            observed: observedChangeCount
           ) {
            disposition = processCatchUp(
                after: lastChangeCount,
                observed: observedChangeCount,
                generation: lifecycle
            )
            return
        }
        guard !consumeInternalWrite(changeCount: observedChangeCount) else { return }
        disposition = processFreshChange(changeCount: observedChangeCount, generation: lifecycle)
    }

    private func processPendingRetryOrSkipInternalWrite(
        _ pending: MacClippyPasteboardReadRetryState.Pending,
        changeCount: Int,
        generation: UInt64
    ) -> PasteboardPollReadDisposition {
        guard !consumeInternalWrite(changeCount: changeCount) else { return .completed }
        return processPendingRetry(pending, generation: generation)
    }

    private func beginRecoveryRead(
        observedChangeCount: Int
    ) -> Bool {
        guard recoveryReadRequested || !recoveryReadCompletions.isEmpty else { return false }
        recoveryReadRequested = false
        guard recoverySuppressedChangeCount != observedChangeCount else {
            return true
        }
        // Read only the current generation; never replay an older dropped snapshot.
        lastChangeCount = nil
        return false
    }

    private func finishRecoveryRead(
        _ disposition: PasteboardPollReadDisposition,
        observedChangeCount: Int,
        lifecycle: UInt64
    ) {
        switch disposition {
        case .completed:
            // `readOutcome()` can stabilize on and materialize a newer
            // generation than the count sampled at poll entry. Report the
            // generation the observer actually processed so admission cannot
            // discard a newer overload candidate as if it were stale.
            completeRecoveryReadWaiters(
                isCurrentLifecycle(lifecycle) ? (lastChangeCount ?? observedChangeCount) : nil
            )
        case .retry:
            recoveryReadRequested = !recoveryReadCompletions.isEmpty
        case .cancelled:
            completeRecoveryReadWaiters(nil)
        }
    }

    func completeRecoveryReadWaiters(_ result: Int?) {
        recoveryReadRequested = false
        let completions = recoveryReadCompletions
        recoveryReadCompletions.removeAll()
        completions.forEach { $0(result) }
    }

}
