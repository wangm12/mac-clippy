import Foundation

import MacClippyCore

public extension MacClippyPasteboardObserver {
    /// Updates capture exclusions without restarting the polling timer. The
    /// settings UI can call this from the main thread; the update is queued
    /// onto the same serial executor as polling so it never races delivery or
    /// blocks the caller behind a provider read.
    func updateExclusionRules(_ rules: MacClippyCore.CaptureExclusionRules) {
        enqueueOnLifecycleQueue { [weak self] in
            self?.exclusionRules = rules
        }
    }

    func setCapturePaused(_ paused: Bool) {
        enqueueOnLifecycleQueue { [weak self] in
            self?.capturePaused = paused
        }
    }

    func start(handler: @escaping Handler) {
        start(projectionHandler: { change, _ in handler(change) })
    }

    func start(projectionHandler: @escaping ProjectionHandler) {
        let generation = transitionLifecycle(started: true)
        // Starting is intentionally non-blocking as well as stopping. The
        // initial change-count read touches NSPasteboard providers and must
        // never make a main-thread restart wait behind an in-flight provider
        // read from the previous generation.
        enqueueOnLifecycleQueue { [weak self] in
            guard let self else { return }
            guard self.isCurrentLifecycle(generation) else { return }
            self.stopOnLifecycleQueue()
            self.projectionHandler = projectionHandler
            self.lastChangeCount = self.reader.currentChangeCount()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval)
            timer.setEventHandler { [weak self] in self?.pollOnLifecycleQueue() }
            self.timer = timer
            timer.resume()
        }
    }

    // Cancels the timer and drops the handler. Also clears cross-poll retry
    // state and resets the write sentinel's pending tokens so a subsequent
    // start() never inherits stale state from a previous session. Safe to
    // call from any thread: retryState and the sentinel are lock-protected,
    // and the timer/handler handoff is ordered so an in-flight poll() on the
    // observer's queue either completes before the clear or sees the cleared
    // state under the locks. The transition is marked before enqueueing the
    // cleanup so callers never wait for an in-flight provider read or retry.
    func stop() {
        let generation = transitionLifecycle(started: false)
        // These collaborators are independently synchronized, so clear them
        // before enqueueing the non-blocking lifecycle cleanup. This makes a
        // stop observable immediately even when a provider read is in flight.
        retryState.clearAll()
        writeSentinel?.reset()
        enqueueOnLifecycleQueue { [weak self] in
            guard let self, self.lifecycleGenerationValue() == generation else { return }
            self.stopOnLifecycleQueue()
        }
    }

    func poll() {
        onLifecycleQueue { [weak self] in
            self?.pollOnLifecycleQueue()
        }
    }

    private func onLifecycleQueue(_ operation: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: lifecycleKey) != nil {
            operation()
        } else {
            queue.sync(execute: DispatchWorkItem(block: operation))
        }
    }

    private func enqueueOnLifecycleQueue(_ operation: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: lifecycleKey) != nil {
            operation()
        } else {
            queue.async(execute: DispatchWorkItem(block: operation))
        }
    }

    private func stopOnLifecycleQueue() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        projectionHandler = nil
        retryState.clearAll()
        writeSentinel?.reset()
    }

    private func transitionLifecycle(started: Bool) -> UInt64 {
        lifecycleStateLock.lock()
        lifecycleGeneration &+= 1
        lifecycleStarted = started
        let generation = lifecycleGeneration
        lifecycleStateLock.unlock()
        return generation
    }

    private func lifecycleGenerationValue() -> UInt64 {
        lifecycleStateLock.lock()
        defer { lifecycleStateLock.unlock() }
        return lifecycleGeneration
    }

    private func isLifecycleStarted() -> Bool {
        lifecycleStateLock.lock()
        defer { lifecycleStateLock.unlock() }
        return lifecycleStarted
    }

    private func isCurrentLifecycle(_ generation: UInt64) -> Bool {
        lifecycleStateLock.lock()
        defer { lifecycleStateLock.unlock() }
        return lifecycleStarted && lifecycleGeneration == generation
    }

    private func pollOnLifecycleQueue() {
        let generation = lifecycleGenerationValue()
        guard isCurrentLifecycle(generation) else { return }
        let observedChangeCount = reader.currentChangeCount()
        guard !capturePaused else {
            retryState.clear(changeCount: observedChangeCount)
            lastChangeCount = observedChangeCount
            return
        }

        // Suppress only exact internal writes originating from Mac Clippy.
        // The sentinel consumes the token on first match so a later external
        // write is never hidden. External content (including concealed,
        // transient, custom, and unknown UTIs) is never filtered here.
        guard !consumeInternalWrite(changeCount: observedChangeCount) else { return }

        // Cross-poll retry for lazy provider data. When a new changeCount
        // arrives with advertised-but-unavailable UTIs, withhold
        // lastChangeCount advancement (and thus delivery) and record the
        // pending types so subsequent polls can re-read them. After the retry
        // budget, deliver the change with every still-unavailable advertised
        // UTI carried as an .unavailable marker instead of dropping the type.
        if let pending = retryState.pending(for: observedChangeCount) {
            processPendingRetry(pending, generation: generation)
            return
        }

        guard lastChangeCount != observedChangeCount else { return }
        processFreshChange(generation: generation)
    }

    private func consumeInternalWrite(changeCount: Int) -> Bool {
        guard let writeSentinel, writeSentinel.consume(changeCount: changeCount) else {
            return false
        }
        retryState.clear(changeCount: changeCount)
        lastChangeCount = changeCount
        return true
    }

    private func processPendingRetry(
        _ pending: MacClippyPasteboardReadRetryState.Pending,
        generation: UInt64
    ) {
        let change = pending.originalChange ?? reader.read(shouldContinue: { [weak self] in
            self?.isCurrentLifecycle(generation) ?? false
        })
        let changeCount = change.changeCount
        guard isCurrentLifecycle(generation) else { return }
        let reread = reader.reread(
            change: change,
            unavailableTypes: pending.unavailableTypes,
            shouldContinue: { [weak self] in self?.isCurrentLifecycle(generation) ?? false }
        )
        guard isCurrentLifecycle(generation) else { return }
        guard reader.currentChangeCount() == changeCount else {
            // The provider reread crossed a new pasteboard generation. Never
            // deliver bytes from the old generation.
            retryState.clear(changeCount: changeCount)
            return
        }
        let stillUnavailable = MacClippyPasteboardAvailability.unavailableTypes(in: reread)
        guard !stillUnavailable.isEmpty else {
            retryState.clear(changeCount: changeCount)
            deliver(reread, changeCount: changeCount)
            return
        }
        retryState.updateUnavailableTypes(
            for: changeCount,
            unavailableTypes: stillUnavailable
        )
        guard !retryState.incrementAttempts(for: changeCount) else { return }
        retryState.clear(changeCount: changeCount)
        deliver(reread, changeCount: changeCount)
    }

    private func processFreshChange(generation: UInt64) {
        // The generation changed, so pay the cost of materializing all
        // advertised representations exactly once for this poll.
        let change = reader.read(shouldContinue: { [weak self] in
            self?.isCurrentLifecycle(generation) ?? false
        })
        guard isCurrentLifecycle(generation) else { return }
        let changeCount = change.changeCount
        guard lastChangeCount != changeCount,
              reader.currentChangeCount() == changeCount else {
            // A pasteboard write raced materialization. The next poll reads
            // the current generation from scratch.
            return
        }

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

    private func deliver(_ change: PasteboardChange, changeCount: Int) {
        guard isLifecycleStarted() else { return }
        lastChangeCount = changeCount
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

        let projection = MacClippyCaptureMapper.projection(for: change)
        let textExcluded = !rules.excludedTextPatterns.isEmpty
            && projection.searchableText.map { rules.shouldExcludeText($0) } == true
        guard !textExcluded else { return }
        projectionHandler?(change, projection)
    }
}
