import Foundation

import MacClippyCore

extension MacClippyRuntime {
    func withStoreLock<T>(_ operation: () throws -> T) rethrows -> T {
        storeLock.lock()
        beginStoreLockOnCurrentThread()
        defer {
            endStoreLockOnCurrentThread()
            storeLock.unlock()
        }
        return try operation()
    }

    var isStoreLockHeldOnCurrentThread: Bool {
        ((Thread.current.threadDictionary[Self.storeLockHeldThreadKey] as? Int) ?? 0) > 0
    }

    private func beginStoreLockOnCurrentThread() {
        let thread = Thread.current
        let depth = (thread.threadDictionary[Self.storeLockHeldThreadKey] as? Int) ?? 0
        thread.threadDictionary[Self.storeLockHeldThreadKey] = depth + 1
        #if DEBUG
        storeLockMetricsLock.lock()
        storeLockAcquisitionCountValue += 1
        storeLockMetricsLock.unlock()
        #endif
    }

    private func endStoreLockOnCurrentThread() {
        let thread = Thread.current
        let depth = (thread.threadDictionary[Self.storeLockHeldThreadKey] as? Int) ?? 1
        thread.threadDictionary[Self.storeLockHeldThreadKey] = max(0, depth - 1)
    }

    func readImageBlob(id: String, maxBytes: Int) throws -> Data {
        #if DEBUG
        if isStoreLockHeldOnCurrentThread {
            storeLockMetricsLock.lock()
            blobReadsWhileStoreLockHeldValue += 1
            storeLockMetricsLock.unlock()
        }
        #endif
        return try blobStore.read(id: id, maxBytes: maxBytes)
    }

    #if DEBUG
    var storeLockAcquisitionCount: Int {
        storeLockMetricsLock.lock()
        defer { storeLockMetricsLock.unlock() }
        return storeLockAcquisitionCountValue
    }

    var blobReadsWhileStoreLockHeld: Int {
        storeLockMetricsLock.lock()
        defer { storeLockMetricsLock.unlock() }
        return blobReadsWhileStoreLockHeldValue
    }

    func resetStoreLockMetricsForTesting() {
        storeLockMetricsLock.lock()
        storeLockAcquisitionCountValue = 0
        blobReadsWhileStoreLockHeldValue = 0
        storeLockMetricsLock.unlock()
    }
    #endif

    // Database queues are closed only after all work already submitted to the
    // capture queue has reached a terminal state. The specific-value guard
    // keeps this safe if teardown is ever initiated by a capture-queue task.
    func drainCaptureQueueForShutdown() {
        guard DispatchQueue.getSpecific(key: captureQueueKey) == nil else { return }
        captureQueue.sync {}
    }

    func drainMaintenanceQueueForShutdown() {
        guard DispatchQueue.getSpecific(key: maintenanceQueueKey) == nil else { return }
        maintenanceQueue.sync {}
    }

    /// Waits for canceled OCR operations to relinquish their input Data, then
    /// drains their completion accounting on captureQueue. Ordinary stop does
    /// not call this; replacement/teardown does so off-main before reopening a
    /// root with a fresh OCR budget.
    func drainOCRQueueForShutdown() {
        ocrQueue.waitUntilAllOperationsAreFinished()
        drainCaptureQueueForShutdown()
    }

    /// Waits for lifecycle-bound transactions that already passed admission.
    /// Ordinary stop only invalidates the generation and never takes this
    /// fence; replacement/teardown calls it from a background queue after
    /// producers have stopped and their owned queues have drained.
    func drainLifecycleCommitsForShutdown() {
        lifecycleCommitLock.lock()
        lifecycleCommitLock.unlock()
    }

    func activeLifecycleToken() -> MacClippyRuntimeLifecycleToken? {
        withLifecycleStateLock {
            guard running else { return nil }
            return MacClippyRuntimeLifecycleToken(generation: lifecycleGeneration)
        }
    }

    func isCurrentLifecycleToken(_ token: MacClippyRuntimeLifecycleToken) -> Bool {
        withLifecycleStateLock { running && lifecycleGeneration == token.generation }
    }

    @discardableResult
    func withCurrentLifecycleStoreLock<T>(
        _ token: MacClippyRuntimeLifecycleToken,
        _ operation: () throws -> T
    ) rethrows -> T? {
        lifecycleCommitLock.lock()
        defer { lifecycleCommitLock.unlock() }
        storeLock.lock()
        beginStoreLockOnCurrentThread()
        defer {
            endStoreLockOnCurrentThread()
            storeLock.unlock()
        }
        guard isCurrentLifecycleToken(token) else { return nil }
        return try operation()
    }

    func performCurrentLifecycleCommit(
        _ token: MacClippyRuntimeLifecycleToken,
        _ operation: () throws -> Void
    ) throws {
        guard try withCurrentLifecycleStoreLock(token, operation) != nil else {
            throw CancellationError()
        }
    }

    func withLifecycleStateLock<T>(_ operation: () throws -> T) rethrows -> T {
        lifecycleStateLock.lock()
        defer { lifecycleStateLock.unlock() }
        return try operation()
    }

    @discardableResult
    func beginLifecycle() -> MacClippyRuntimeLifecycleToken? {
        withLifecycleStateLock {
            guard !running else { return nil }
            running = true
            lifecycleGeneration &+= 1
            return MacClippyRuntimeLifecycleToken(generation: lifecycleGeneration)
        }
    }

    func invalidateLifecycle() {
        // A commit that has already passed its token check is admitted and may
        // finish its SQLite transaction. New callers observe the changed
        // generation after acquiring lifecycleCommitLock/storeLock and are
        // rejected before touching storage. Ordinary stop must not wait for a
        // slow provider, OCR recognizer, maintenance pass, or SQLite write;
        // restore/teardown explicitly drains the commit fence off-main before
        // closing or replacing database files.
        withLifecycleStateLock {
            lifecycleGeneration &+= 1
            running = false
        }
    }

    // This helper keeps the lifecycle transition state change explicit at
    // call sites and avoids accidentally coupling cancellation to storage.
    func isLifecycleRunning() -> Bool {
        withLifecycleStateLock { running }
    }

}
