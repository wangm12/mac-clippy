import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    /// Stops producers, drains runtime-owned storage queues, then explicitly
    /// closes every SQLite writer before a restore can replace the files.
    /// The caller removes this runtime from the UI before invoking this method
    /// so no new app operation can be scheduled against the old stores.
    func closeStorageForRestore() throws {
        stop()
        drainCaptureQueueForShutdown()
        drainMaintenanceQueueForShutdown()
        drainOCRQueueForShutdown()
        drainLifecycleCommitsForShutdown()
        thumbnailDiskCache.retireForRestore()

        try withStoreLock {
            var firstError: Error?
            for database in databases {
                do {
                    try database.closeForReplacement()
                } catch {
                    if firstError == nil { firstError = error }
                    MacClippyLog.record(
                        category: .storage,
                        code: .databaseHealthFailed,
                        operation: "database_close_for_restore",
                        recoveryAction: "retry_restore_after_restart",
                        impact: "restore_storage_close_failed"
                    )
                }
            }
            if let firstError { throw firstError }
        }
    }

    #if DEBUG
        func closeForTesting() {
            stop()
            drainCaptureQueueForShutdown()
            drainMaintenanceQueueForShutdown()
            drainOCRQueueForShutdown()
            drainLifecycleCommitsForShutdown()
            // Test fixtures remove their temporary database root immediately
            // after this hook returns. Close the queues here, rather than
            // relying on ARC to run `deinit` after the test teardown has
            // already started removing WAL/SHM files.
            databases.forEach { database in
                do {
                    try database.queue.close()
                } catch {
                    MacClippyLog.record(
                        category: .storage,
                        code: .databaseHealthFailed,
                        operation: "database_close_for_testing",
                        recoveryAction: "retry_on_next_launch",
                        impact: "database_close_failed"
                    )
                }
            }
        }

        // Fault-injection hook for tests that need an infrastructure write to
        // fail after a user-visible operation has already succeeded. Normal
        // teardown must use closeForTesting() so queued work is drained first.
        func closeStorageForTesting() {
            databases.forEach { database in
                do {
                    try database.queue.close()
                } catch {
                    MacClippyLog.record(
                        category: .storage,
                        code: .databaseHealthFailed,
                        operation: "database_close_for_testing",
                        recoveryAction: "retry_on_next_launch",
                        impact: "database_close_failed"
                    )
                }
            }
        }
    #endif

    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { [self] in start() }
            return
        }
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard let lifecycleToken = beginLifecycle() else { return }
        scheduleStartupMaintenance(for: lifecycleToken)
        scheduleRetentionTimer(for: lifecycleToken)
        observeLifecycleNotifications()
        if usesRuntimeExclusionRules {
            observer.updateExclusionRules(
                MacClippyRetentionPreferences.exclusionRules(from: preferencesDefaults)
            )
            applyCapturePausePreference()
        }
        observer.start(
            admissionHandler: { [weak self] change in
                guard let self, self.isCurrentLifecycleToken(lifecycleToken) else { return nil }
                return self.captureQueueAdmission.admission(for: change)
            },
            admittedProjectionHandler: { [weak self] change, projection, admission in
                guard let self else {
                    admission.finish(wasPersisted: false)
                    return
                }
                let job = MacClippyRuntimeCaptureJob(
                    change: change,
                    projection: projection,
                    admission: admission
                )
                self.captureQueue.async { [weak self, job] in
                    let persisted = job.persist { change, projection in
                        guard let self else { return false }
                        return self.capture(
                            change,
                            projection: projection,
                            for: lifecycleToken
                        )
                    }
                    job.finish(wasPersisted: persisted)
                }
            }
        )
        requestCaptureQueueRecoveryIfPossible()
        if snippetExpansionEnabled {
            _ = snippetExpander.start()
        }
    }

    private func scheduleStartupMaintenance(for lifecycleToken: MacClippyRuntimeLifecycleToken) {
        maintenanceQueue.async { [weak self] in
            guard let self,
                  self.isCurrentLifecycleToken(lifecycleToken) else { return }
            self.retentionPreferencesSnapshot = MacClippyRetentionPreferencesSnapshot(
                defaults: self.preferencesDefaults
            )
            self.reconcileStorage(for: lifecycleToken)
            self.enforceRetention(for: lifecycleToken)
        }
    }

    private func scheduleRetentionTimer(for lifecycleToken: MacClippyRuntimeLifecycleToken) {
        let timer = DispatchSource.makeTimerSource(queue: maintenanceQueue)
        timer.schedule(deadline: .now() + 3_600, repeating: 3_600)
        timer.setEventHandler { [weak self] in
            self?.enforceRetention(for: lifecycleToken)
        }
        retentionTimer = timer
        timer.resume()
    }

    private func observeLifecycleNotifications() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: preferencesDefaults,
            queue: nil
        ) { [weak self] _ in
            self?.captureQueue.async { [weak self] in
                guard let self, let lifecycleToken = self.activeLifecycleToken() else { return }
                self.handleDefaultsChange(for: lifecycleToken)
            }
        }
        ocrPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.captureQueue.async { [weak self] in
                self?.startDeferredOCRIfReady()
            }
        }
    }

    func stop() {
        // Backup and compression cancellation is a short state update. It
        // must happen before any lifecycle/store draining so an ordinary UI
        // stop can ask off-lock maintenance work to stop without waiting for
        // its filesystem or image-processing calls.
        cancelBulkMaintenanceIO()
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { [self] in stop() }
            return
        }
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        // Reject new lifecycle-bound admission before asking producers to
        // stop. A transaction that already passed the token check may finish;
        // later observer deliveries cannot reserve another capture slot.
        invalidateLifecycle()
        captureQueueAdmission.observerDidStop()

        // Stop producers first so no new observer/timer work is submitted.
        // The lifecycle transition above is nonblocking with respect to
        // storage. A transaction that already passed its token check may
        // complete; work not yet admitted observes the invalidated generation.
        observer.stop()
        snippetExpander.stop()
        ocrQueue.cancelAllOperations()
        cancelOCRScheduleTimer()
        cancelCapturePauseTimer()
        if let ocrPowerObserver {
            NotificationCenter.default.removeObserver(ocrPowerObserver)
            self.ocrPowerObserver = nil
        }
        retentionTimer?.setEventHandler {}
        retentionTimer?.cancel()
        retentionTimer = nil
        maintenanceQueue.async { [weak self] in
            self?.retentionDebounceWorkItem?.cancel()
            self?.retentionDebounceWorkItem = nil
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        captureQueue.async { [weak self] in
            guard let self else { return }
            var deferredJobs = self.deferredOCRJobs
            self.deferredOCRJobs.removeAll(keepingCapacity: true)
            let reservations = deferredJobs.map { job in
                (generation: job.lifecycleToken.generation, byteCount: job.data.count)
            }
            // Drop this local COW array as well as the stored queue before
            // releasing counters, so no deferred Data remains retained.
            deferredJobs.removeAll(keepingCapacity: false)
            reservations.forEach {
                self.releaseOCRReservation(
                    generation: $0.generation,
                    byteCount: $0.byteCount
                )
            }
        }
    }

    func requestCaptureQueueRecoveryIfPossible() {
        guard isRunning,
              captureQueueAdmission.beginCurrentGenerationReadIfPossible() else {
            return
        }
        observer.requestCurrentGenerationRead { [weak self] changeCount in
            self?.captureQueueAdmission.currentGenerationReadCompleted(changeCount: changeCount)
        }
    }

    func noteDisplayLifecycleForCapture(_ event: MacClippyDisplayLifecycleEvent) {
        guard let suspended = MacClippyDisplayGenerationPolicy.shouldSuspendPasteboardPolling(for: event) else {
            return
        }
        observer.setPollingSuspended(suspended)
    }

    func ignoreNextCopy() {
        observer.ignoreNextCopy()
    }

    func applyCapturePausePreference(now: Date = Date()) {
        let defaults = preferencesDefaults
        let wantsPause = defaults.bool(forKey: MacClippyRetentionPreferences.privacyPauseKey)
        let until = MacClippyRetentionPreferences.pauseUntil(from: defaults)
        guard wantsPause else {
            observer.setCapturePaused(false)
            cancelCapturePauseTimer()
            return
        }
        if let until {
            guard MacClippyCapturePausePolicy.isActive(now: now, until: until) else {
                defaults.set(false, forKey: MacClippyRetentionPreferences.privacyPauseKey)
                defaults.removeObject(forKey: MacClippyRetentionPreferences.pauseUntilKey)
                observer.setCapturePaused(false)
                cancelCapturePauseTimer()
                return
            }
            observer.setCapturePaused(true)
            armCapturePauseTimer(until: until)
            return
        }
        observer.setCapturePaused(true)
        cancelCapturePauseTimer()
    }

    func armCapturePauseTimer(until: Date?) {
        cancelCapturePauseTimer()
        guard let until, until < Date.distantFuture else { return }
        let delay = until.timeIntervalSinceNow
        guard delay > 0 else {
            applyCapturePausePreference()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.applyCapturePausePreference()
        }
        MacClippyRuntimeTimerLock.lock.lock()
        capturePauseTimer = timer
        MacClippyRuntimeTimerLock.lock.unlock()
        timer.resume()
    }

    func cancelCapturePauseTimer() {
        MacClippyRuntimeTimerLock.lock.lock()
        let timer = capturePauseTimer
        capturePauseTimer = nil
        MacClippyRuntimeTimerLock.lock.unlock()
        timer?.setEventHandler {}
        timer?.cancel()
    }

    func refreshPermissionDependentFeatures() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { [self] in refreshPermissionDependentFeatures() }
            return
        }
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard isLifecycleRunning() else { return }
        guard snippetExpansionEnabled else {
            snippetExpander.stop()
            return
        }
        if AXIsProcessTrusted(), CGPreflightListenEventAccess() {
            _ = snippetExpander.start()
        } else {
            snippetExpander.stop()
        }
    }

    static func defaultKeychain(paths: MacClippyPaths?) -> MacClippyKeychainBackend {
        if paths != nil || NSClassFromString("XCTestCase") != nil {
            return MacClippyInMemoryKeychain.shared
        }
        return MacClippySystemKeychain()
    }
}
