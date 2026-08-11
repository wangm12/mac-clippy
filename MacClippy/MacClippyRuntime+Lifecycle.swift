import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    #if DEBUG
        func closeForTesting() {
            stop()
            drainCaptureQueueForShutdown()
            drainMaintenanceQueueForShutdown()
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
        // OCR completions from an older generation may still be draining
        // after OperationQueue cancellation. Reset the active-generation
        // accounting on the capture queue before new work is admitted; old
        // completions are generation-checked and cannot decrement this value.
        captureQueue.async { [weak self] in
            guard let self,
                  self.isCurrentLifecycleToken(lifecycleToken) else { return }
            self.pendingOCRJobs = 0
            self.pendingOCRBytes = 0
            self.pendingOCRJobsByGeneration[lifecycleToken.generation] = 0
            self.pendingOCRBytesByGeneration[lifecycleToken.generation] = 0
        }
        // Off-main startup reconciliation: trim orphan blobs and FTS rows left
        // behind by a crash mid-capture. Best-effort; failures are logged and
        // never block capture from starting. Maintenance has its own queue so
        // this scan cannot occupy the capture queue.
        maintenanceQueue.async { [weak self] in
            guard let self else { return }
            guard self.isCurrentLifecycleToken(lifecycleToken) else { return }
            self.retentionPreferencesSnapshot = MacClippyRetentionPreferencesSnapshot(defaults: .standard)
            self.reconcileStorage(for: lifecycleToken)
            self.enforceRetention(for: lifecycleToken)
        }
        let retentionTimer = DispatchSource.makeTimerSource(queue: maintenanceQueue)
        retentionTimer.schedule(deadline: .now() + 3_600, repeating: 3_600)
        retentionTimer.setEventHandler { [weak self] in
            self?.enforceRetention(for: lifecycleToken)
        }
        self.retentionTimer = retentionTimer
        retentionTimer.resume()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { [weak self] _ in
            self?.captureQueue.async { [weak self] in
                guard let self, let lifecycleToken = self.activeLifecycleToken() else { return }
                self.handleDefaultsChange(for: lifecycleToken)
            }
        }
        if usesRuntimeExclusionRules {
            observer.updateExclusionRules(MacClippyRetentionPreferences.exclusionRules())
            observer.setCapturePaused(UserDefaults.standard.bool(forKey: MacClippyRetentionPreferences.privacyPauseKey))
        }
        observer.start(projectionHandler: { [weak self] change, projection in
            // Hand the change to the capture queue so mapping, encryption, and
            // DB writes never block the observer's poll loop or the main
            // thread.
            guard let self else { return }
            self.captureQueue.async { [self] in
                self.capture(change, projection: projection, for: lifecycleToken)
            }
        })
        _ = snippetExpander.start()
    }

    func stop() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { [self] in stop() }
            return
        }
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        // Stop producers first so no new observer/timer work is submitted.
        // The lifecycle is invalidated while holding storeLock below. An
        // already-running capture either completes before that transition or
        // observes the invalidated token before entering storage; this closes
        // the commit window where stop could invalidate a generation while its
        // transaction was still writing.
        observer.stop()
        snippetExpander.stop()
        ocrQueue.cancelAllOperations()
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
        // Invalidate through the lifecycle commit gate. This may wait for an
        // already-admitted capture/OCR commit, but it cannot wait for an
        // unrelated maintenance pass: those passes use storeLock without the
        // lifecycle gate and keep checking their token between bounded pages.
        invalidateLifecycle()
        captureQueue.async { [weak self] in
            self?.pendingOCRJobs = 0
            self?.pendingOCRBytes = 0
            self?.pendingOCRJobsByGeneration.removeAll()
            self?.pendingOCRBytesByGeneration.removeAll()
        }
    }

    func refreshPermissionDependentFeatures() {
        guard Thread.isMainThread else {
            DispatchQueue.main.sync { [self] in refreshPermissionDependentFeatures() }
            return
        }
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard isLifecycleRunning() else { return }
        if AXIsProcessTrusted(), CGPreflightListenEventAccess() {
            _ = snippetExpander.start()
        } else {
            snippetExpander.stop()
        }
    }
}
