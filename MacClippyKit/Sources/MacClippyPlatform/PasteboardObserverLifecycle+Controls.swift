import Foundation

import MacClippyCore

public extension MacClippyPasteboardObserver {
    /// Updates capture exclusions without restarting the polling timer. The
    /// settings UI can call this from the main thread; the update is queued
    /// onto the same serial executor as polling so it never races delivery or
    /// blocks the caller behind a provider read.
    func updateExclusionRules(_ rules: MacClippyCore.CaptureExclusionRules) {
        enqueueOnLifecycleQueue { [weak self] in
            self?.applyExclusionRulesOnLifecycleQueue(rules)
        }
    }

    func setCapturePaused(_ paused: Bool) {
        enqueueOnLifecycleQueue { [weak self] in
            self?.capturePaused = paused
            self?.publishCaptureStatus()
        }
    }

    func ignoreNextCopy() {
        enqueueOnLifecycleQueue { [weak self] in
            self?.ignoreNextCopyCount += 1
            self?.publishCaptureStatus()
        }
    }

    /// Cancels or rearms the poll timer without stopping the observer session.
    /// Sleep uses this so the 50ms timer does not fire while screens are off.
    /// `lastChangeCount` is left alone so a copy that lands during sleep is
    /// still visible on the first poll after wake. Independent of privacy pause.
    func setPollingSuspended(_ suspended: Bool) {
        enqueueOnLifecycleQueue { [weak self] in
            self?.applyPollingSuspended(suspended)
        }
    }

    func isPollingSuspendedForTesting() -> Bool {
        var suspended = false
        onLifecycleQueue { [weak self] in
            suspended = self?.pollingSuspended ?? false
        }
        return suspended
    }

    func hasPollingTimerForTesting() -> Bool {
        var armed = false
        onLifecycleQueue { [weak self] in
            armed = self?.timer != nil
        }
        return armed
    }

    package func disableAutomaticPollingForTesting() {
        onLifecycleQueue { [weak self] in
            guard let self else { return }
            self.automaticPollingEnabled = false
            self.cancelPollingTimerOnLifecycleQueue()
        }
    }

    func pollIntervalForTesting() -> TimeInterval {
        var interval: TimeInterval = 0
        onLifecycleQueue { [weak self] in
            interval = self?.pollInterval ?? 0
        }
        return interval
    }

    /// Changes the awake poll cadence. Sleep still owns cancel/rearm; this
    /// only reschedules the timer when polling is already running.
    func setPollActivity(_ activity: MacClippyPasteboardPollActivity) {
        enqueueOnLifecycleQueue { [weak self] in
            self?.applyPollActivity(activity)
        }
    }

    func start(handler: @escaping Handler) {
        start(projectionHandler: { change, _ in handler(change) })
    }

    func start(projectionHandler: @escaping ProjectionHandler) {
        start(
            admissionHandler: nil,
            admittedProjectionHandler: nil,
            projectionHandler: projectionHandler
        )
    }

    func start(
        admissionHandler: @escaping AdmissionHandler,
        admittedProjectionHandler: @escaping AdmittedProjectionHandler
    ) {
        start(
            admissionHandler: admissionHandler,
            admittedProjectionHandler: admittedProjectionHandler,
            projectionHandler: nil
        )
    }

    private func start(
        admissionHandler: AdmissionHandler?,
        admittedProjectionHandler: AdmittedProjectionHandler?,
        projectionHandler: ProjectionHandler?
    ) {
        let generation = transitionLifecycle(started: true)
        // Starting is intentionally non-blocking as well as stopping. The
        // initial change-count read touches NSPasteboard providers and must
        // never make a main-thread restart wait behind an in-flight provider
        // read from the previous generation.
        enqueueOnLifecycleQueue { [weak self] in
            guard let self else { return }
            guard self.isCurrentLifecycle(generation) else { return }
            let previousChangeCount = self.lastChangeCount
            let currentChangeCount = self.reader.currentChangeCount()
            let pendingIgnoreDisposition =
                self.ignoreNextCopyCount > 0 || self.restartIgnoreNextCopyDisposition
            let wasInternalWrite = self.writeSentinel?.consumeAndPrune(through: currentChangeCount) ?? false
            let generationChangedWhileStopped = previousChangeCount != currentChangeCount
            let suppressCurrentGeneration = wasInternalWrite || (
                generationChangedWhileStopped && (
                    self.capturePaused || (pendingIgnoreDisposition && !wasInternalWrite)
                )
            )
            self.stopOnLifecycleQueue(preserveIgnoreDisposition: false)
            self.projectionHandler = projectionHandler
            self.admissionHandler = admissionHandler
            self.admittedProjectionHandler = admittedProjectionHandler
            self.lastChangeCount = currentChangeCount
            if suppressCurrentGeneration {
                self.recoverySuppressedChangeCount = currentChangeCount
            }
            self.pollingSuspended = false
            self.refreshPollActivityOnLifecycleQueue()
            self.armPollingTimerOnLifecycleQueue()
        }
    }

    // Cancels the timer and drops the handler. Also clears cross-poll retry
    // state. A write token remains until the next start can compare it with the
    // current generation; this preserves an own-write disposition across a
    // stop without reading the pasteboard on the caller's thread. Safe to call
    // from any thread: retryState and the sentinel are lock-protected,
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
        enqueueOnLifecycleQueue { [weak self] in
            guard let self, self.lifecycleGenerationValue() == generation else { return }
            self.stopOnLifecycleQueue(preserveIgnoreDisposition: true)
        }
    }

    func poll() {
        onLifecycleQueue { [weak self] in
            self?.pollOnLifecycleQueue()
        }
    }

    /// Requests one bounded read of the current pasteboard generation. On a
    /// completed read, the callback receives the generation the observer
    /// materialized (which can be newer than the count sampled at poll entry). The
    /// request waits through privacy pause and display suspension, then runs
    /// through the same generation checks, own-write sentinel, exclusions, and
    /// provider retry policy as ordinary polling. It never replays a saved
    /// older PasteboardChange.
    func requestCurrentGenerationRead(completion: @escaping (Int?) -> Void) {
        enqueueOnLifecycleQueue { [weak self] in
            guard let self,
                  self.isCurrentLifecycle(self.lifecycleGenerationValue()) else {
                completion(nil)
                return
            }
            guard self.recoveryReadCompletions.count < Self.maximumRecoveryReadWaiters else {
                completion(nil)
                return
            }
            self.recoveryReadCompletions.append(completion)
            self.recoveryReadRequested = true
            self.pollOnLifecycleQueue()
        }
    }

    private func onLifecycleQueue(_ operation: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: lifecycleKey) != nil {
            operation()
        } else {
            queue.sync(execute: DispatchWorkItem(block: operation))
        }
    }

    func enqueueOnLifecycleQueue(_ operation: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: lifecycleKey) != nil {
            operation()
        } else {
            queue.async(execute: DispatchWorkItem(block: operation))
        }
    }

    private func stopOnLifecycleQueue(preserveIgnoreDisposition: Bool) {
        cancelPollingTimerOnLifecycleQueue()
        pollingSuspended = false
        if preserveIgnoreDisposition {
            restartIgnoreNextCopyDisposition = restartIgnoreNextCopyDisposition || ignoreNextCopyCount > 0
        } else {
            restartIgnoreNextCopyDisposition = false
        }
        ignoreNextCopyCount = 0
        projectionHandler = nil
        admissionHandler = nil
        admittedProjectionHandler = nil
        recoveryReadRequested = false
        failedReadChangeCount = nil
        failedReadAttempts = 0
        retryState.clearAll()
        completeRecoveryReadWaiters(nil)
    }

    func refreshPollActivityOnLifecycleQueue() {
        let sinceChange = lastObservedChangeAt.map { now().timeIntervalSince($0) }
        applyPollActivity(
            MacClippyPasteboardPollPolicy.activity(
                secondsSinceLastUserInput: secondsSinceLastUserInput(),
                secondsSinceLastObservedChange: sinceChange
            )
        )
    }

    func noteObservedChangeOnLifecycleQueue() {
        lastObservedChangeAt = now()
        refreshPollActivityOnLifecycleQueue()
    }

    private func applyPollActivity(_ activity: MacClippyPasteboardPollActivity) {
        let interval = MacClippyPasteboardPollPolicy.pollInterval(for: activity)
        let intervalChanged = pollInterval != interval
        pollActivity = activity
        pollInterval = interval
        guard intervalChanged else { return }
        guard isLifecycleStarted(), !pollingSuspended, hasDeliveryHandler else { return }
        cancelPollingTimerOnLifecycleQueue()
        armPollingTimerOnLifecycleQueue()
    }

    private func applyPollingSuspended(_ suspended: Bool) {
        pollingSuspended = suspended
        guard isLifecycleStarted() else { return }
        if suspended {
            cancelPollingTimerOnLifecycleQueue()
            retryState.clearAll()
            failedReadChangeCount = nil
            failedReadAttempts = 0
            return
        }
        guard timer == nil, hasDeliveryHandler else { return }
        armPollingTimerOnLifecycleQueue()
    }

    private var hasDeliveryHandler: Bool {
        projectionHandler != nil || admissionHandler != nil
    }

    private func cancelPollingTimerOnLifecycleQueue() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func armPollingTimerOnLifecycleQueue() {
        guard automaticPollingEnabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval)
        timer.setEventHandler { [weak self] in self?.pollOnLifecycleQueue() }
        self.timer = timer
        timer.resume()
    }

    private func transitionLifecycle(started: Bool) -> UInt64 {
        lifecycleStateLock.lock()
        lifecycleGeneration &+= 1
        lifecycleStarted = started
        let generation = lifecycleGeneration
        lifecycleStateLock.unlock()
        return generation
    }

    func lifecycleGenerationValue() -> UInt64 {
        lifecycleStateLock.lock()
        defer { lifecycleStateLock.unlock() }
        return lifecycleGeneration
    }

    func isLifecycleStarted() -> Bool {
        lifecycleStateLock.lock()
        defer { lifecycleStateLock.unlock() }
        return lifecycleStarted
    }

    func isCurrentLifecycle(_ generation: UInt64) -> Bool {
        lifecycleStateLock.lock()
        defer { lifecycleStateLock.unlock() }
        return lifecycleStarted && lifecycleGeneration == generation
    }
}
