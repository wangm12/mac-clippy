import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    func capture(_ change: PasteboardChange, for lifecycleToken: MacClippyRuntimeLifecycleToken) {
        capture(
            change,
            projection: MacClippyCaptureMapper.projection(for: change),
            for: lifecycleToken
        )
    }

    func capture(
        _ change: PasteboardChange,
        projection: MacClippyCaptureProjection,
        for lifecycleToken: MacClippyRuntimeLifecycleToken
    ) {
        guard isCurrentLifecycleToken(lifecycleToken) else { return }
        measureDiagnosticMetric("capture") {
            guard self.isCurrentLifecycleToken(lifecycleToken) else { return }
            // P0 no-filter capture: retain every external NSPasteboard representation
            // (UTI + raw Data), including concealed, transient, custom, and unknown
            // UTIs. The observer's write sentinel already suppressed Mac Clippy's
            // own writes, so anything that reaches here is external content and is
            // captured without applying the legacy regex/concealed/transient/app
            // exclusions. The primary payload drives the existing card/preview/
            // paste path; the representations array is persisted alongside it so
            // no external representation is lost.
            let payload = projection.payload
            let representations = projection.representations

            // Capture even when no known primary payload is derived, as long as
            // there is at least one external representation. This keeps custom and
            // unknown UTIs visible in history via their representations even when
            // the legacy mapper could not pick a primary slot.
            guard payload != nil || !representations.isEmpty else { return }

            do {
                try persist(
                    payload,
                    representations: representations,
                    sourceAppBundleID: change.sourceAppBundleID,
                    lifecycleToken: lifecycleToken
                )
                // Capture commits happen off-main. Publish only after the
                // transaction succeeds so an active Dock can refresh from a
                // durable record rather than from an optimistic UI event.
                NotificationCenter.default.post(
                    name: .macClippyHistoryDidChange,
                    object: self
                )
            } catch is CancellationError {
                return
            } catch {
                MacClippyLog.record(
                    category: .capture,
                    code: .capturePersistFailed,
                    operation: "capture_persist",
                    recoveryAction: "retry_next_clipboard_change",
                    impact: "clipboard_change_not_saved"
                )
            }
        }
    }

    private func persist(
        _ payload: MacClippyCapturePayload?,
        representations: [MacClippyClipboardRepresentation],
        sourceAppBundleID: String?,
        lifecycleToken: MacClippyRuntimeLifecycleToken
    ) throws {
        guard let result = try withCurrentLifecycleStoreLock(lifecycleToken, { () throws -> (ClipboardItemMeta, Data?) in
            var generatedBlobID: String?
            let record: ClipboardRecord

            switch payload {
            case let .text(value):
                record = .text(value)
            case let .rtf(data):
                record = .rtf(data)
            case let .html(value):
                record = .html(value)
            case let .image(data, width, height):
                let blobID = try blobStore.write(data)
                generatedBlobID = blobID
                record = .image(blobID: blobID, width: width, height: height)
            case let .files(urls):
                record = .files(urls)
            case .none:
                // No known primary slot: synthesize a text preview from the
                // first text-bearing representation so the record is visible
                // in history with a meaningful card. The full representation
                // set is still persisted below.
                let fallbackText = MacClippyCaptureMapper.plainText(for: representations) ?? "(no preview)"
                record = .text(fallbackText)
            }

            let meta: ClipboardItemMeta
            do {
                meta = try clipboardStore.append(
                    record,
                    representations: representations,
                    sourceAppBundleID: sourceAppBundleID,
                    spillPayload: { [blobStore] data in
                        // Spill oversized representation payloads to BlobStore
                        // so the side table stays small; the bytes are
                        // encrypted by BlobStore before they hit disk.
                        try blobStore.write(data)
                    },
                    deleteSpilledPayload: { [weak self, blobStore] blobID in
                        // Compensating rollback for spilled blobs when the
                        // atomic append transaction fails. If the cleanup
                        // itself fails, retain a degraded reason and let
                        // startup reconciliation retry it instead of hiding
                        // an orphan behind a successful-looking capture
                        // failure.
                        do {
                            try blobStore.delete(id: blobID)
                        } catch {
                            self?.storageDegradedReasons.insert("orphan-blob-cleanup-failed")
                            MacClippyLog.record(
                                category: .blob,
                                code: .blobCleanupFailed,
                                operation: "capture_spill_rollback_cleanup",
                                recoveryAction: "run_storage_reconciliation",
                                impact: "capture_failed_with_possible_orphan_blob"
                            )
                        }
                    }
                )
            } catch {
                if let generatedBlobID {
                    do {
                        try blobStore.delete(id: generatedBlobID)
                    } catch {
                        storageDegradedReasons.insert("orphan-blob-cleanup-failed")
                        MacClippyLog.record(
                            category: .blob,
                            code: .blobCleanupFailed,
                            operation: "capture_rollback_blob_cleanup",
                            recoveryAction: "run_storage_reconciliation",
                            impact: "possible_orphan_blob"
                        )
                    }
                }
                throw error
            }

            let searchableText = Self.searchableIndexText(
                for: record,
                ocrText: meta.ocrText,
                label: meta.customLabel,
                representationUTIs: representations.map(\.uti)
            )
            if !searchableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do {
                    try searchStore.upsert(id: meta.id, text: searchableText)
                } catch {
                    markSearchRepairNeededLocked()
                    MacClippyLog.record(
                        category: .fts,
                        code: .ftsIndexFailed,
                        operation: "capture_fts_upsert",
                        recoveryAction: "repair_search_index",
                        impact: "record_saved_but_not_searchable"
                    )
                }
            }

            return (meta, payload?.imageData)
        }) else { return }

        if let imageData = result.1 {
            scheduleOCR(for: imageData, recordID: result.0.id, lifecycleToken: lifecycleToken)
        }

    }

    func enforceRetention(for lifecycleToken: MacClippyRuntimeLifecycleToken) {
        guard isCurrentLifecycleToken(lifecycleToken) else { return }
        let policy = MacClippyRetentionPreferences.policy()
        do {
            guard isCurrentLifecycleToken(lifecycleToken) else { return }
            try performCurrentLifecycleCommit(lifecycleToken) {
                try replayPendingDeletionsLocked(shouldContinue: {
                    self.isCurrentLifecycleToken(lifecycleToken)
                })
            }
            let protectedIDs = try PinboardStore.protectedIDs(from: pinboardStore)
            try policy.enforce(
                store: clipboardStore,
                blobs: blobStore,
                search: searchStore,
                protectedIDs: protectedIDs,
                shouldContinue: { [weak self] in
                    self?.isCurrentLifecycleToken(lifecycleToken) ?? false
                },
                withCommitFence: { [weak self] operation in
                    guard let self else { throw CancellationError() }
                    try self.performCurrentLifecycleCommit(lifecycleToken, operation)
                },
                protectedIDsProvider: { [weak self] in
                    guard let self, self.isCurrentLifecycleToken(lifecycleToken) else {
                        throw CancellationError()
                    }
                    return try PinboardStore.protectedIDs(from: self.pinboardStore)
                }
            )
        } catch is CancellationError {
            return
        } catch {
            storageDegradedReasons.insert("deletion-recovery-pending")
            MacClippyLog.record(
                category: .storage,
                code: .retentionFailed,
                operation: "retention_maintenance",
                recoveryAction: "retry_storage_maintenance",
                impact: "history_cleanup_incomplete"
            )
        }
    }

    func handleDefaultsChange(for lifecycleToken: MacClippyRuntimeLifecycleToken) {
        guard isCurrentLifecycleToken(lifecycleToken) else { return }
        if usesRuntimeExclusionRules {
            observer.updateExclusionRules(MacClippyRetentionPreferences.exclusionRules())
            observer.setCapturePaused(
                UserDefaults.standard.bool(forKey: MacClippyRetentionPreferences.privacyPauseKey)
            )
        }

        // Snippet event taps are AppKit resources and must be changed on the
        // main thread. UserDefaults notifications arrive for every setting,
        // so keep this refresh lightweight and let the expander's mode guard
        // make disabled mode a no-op without requesting permissions.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.refreshPermissionDependentFeatures()
        }

        let nextSnapshot = MacClippyRetentionPreferencesSnapshot(defaults: .standard)
        maintenanceQueue.async { [weak self] in
            guard let self, self.isCurrentLifecycleToken(lifecycleToken) else { return }
            guard nextSnapshot != self.retentionPreferencesSnapshot else { return }
            self.retentionPreferencesSnapshot = nextSnapshot

            self.retentionDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.retentionDebounceWorkItem = nil
                self.enforceRetention(for: lifecycleToken)
            }
            self.retentionDebounceWorkItem = workItem
            self.maintenanceQueue.asyncAfter(deadline: .now() + 0.75, execute: workItem)
        }
    }

    // Best-effort startup reconciliation: trim orphan blobs (no record
    // references them) and orphan FTS rows (no clipboard record for the
    // indexed id). Runs off-main once at start; failures are logged and never
    // block capture. See MacClippyReconciliation for the detection logic.
    func reconcileStorage(for lifecycleToken: MacClippyRuntimeLifecycleToken) {
        guard isCurrentLifecycleToken(lifecycleToken) else { return }
        measureDiagnosticMetric("storage_reconciliation") {
            guard self.isCurrentLifecycleToken(lifecycleToken) else { return }
            // Capture the health snapshot before repair starts. A repairable
            // FTS marker is still a real startup degradation even when the
            // bounded repair below succeeds; recording it here preserves that
            // signal without exposing SQLite details or delaying capture.
            let startupHealth = withStoreLock { storageHealthLocked() }
            let hadStartupIssue = startupHealth.values.contains { $0.status != .healthy }
            recordStartupHealthIfNeeded(health: startupHealth)
            do {
                let outcome = try runStorageReconciliation(for: lifecycleToken)
                guard self.isCurrentLifecycleToken(lifecycleToken) else { return }
                updateReconciliationHealth(outcome.result, for: lifecycleToken)
                recordReconciliationOutcome(
                    outcome.result,
                    ftsRepairSucceeded: outcome.ftsRepairSucceeded
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentLifecycleToken(lifecycleToken) else { return }
                withStoreLock {
                    guard self.isCurrentLifecycleToken(lifecycleToken) else { return }
                    storageDegradedReasons.insert("storage-reconciliation-failed")
                }
                MacClippyLog.record(
                    category: .storage,
                    code: .reconciliationFailed,
                    operation: "startup_reconciliation",
                    recoveryAction: "export_diagnostics_and_retry",
                    impact: "orphan_cleanup_incomplete"
                )
            }

            // Reconciliation can discover a new failure after an initially
            // healthy snapshot. Record that post-recovery state only when the
            // startup snapshot was healthy, avoiding duplicate events for the
            // same already-reported degraded database.
            guard self.isCurrentLifecycleToken(lifecycleToken) else { return }
            if !hadStartupIssue {
                recordStartupHealthIfNeeded()
            }
        }
    }

    private func runStorageReconciliation(
        for lifecycleToken: MacClippyRuntimeLifecycleToken
    ) throws -> (result: MacClippyReconciliation.Result, ftsRepairSucceeded: Bool) {
        try performCurrentLifecycleCommit(lifecycleToken) {
            try replayPendingDeletionsLocked(shouldContinue: {
                self.isCurrentLifecycleToken(lifecycleToken)
            })
        }
        let result = try MacClippyReconciliation.reconcile(
            store: clipboardStore,
            search: searchStore,
            blobs: blobStore,
            shouldContinue: { [weak self] in
                self?.isCurrentLifecycleToken(lifecycleToken) ?? false
            },
            deleteBlob: { [weak self, blobStore] id in
                guard let self else { throw CancellationError() }
                try self.performCurrentLifecycleCommit(lifecycleToken) {
                    // Reconciliation's reachability pass can race with a
                    // capture. Re-check while the lifecycle/store fence is
                    // held immediately before deleting the external file.
                    guard try !self.clipboardStore.isBlobReferenced(id) else { return }
                    try blobStore.delete(id: id)
                }
            },
            deleteFTS: { [weak self, searchStore] id in
                guard let self else { throw CancellationError() }
                try self.performCurrentLifecycleCommit(lifecycleToken) {
                    try searchStore.remove(kind: .clipboardItem, id: id)
                }
            },
            isBlobStillUnreferenced: { [clipboardStore] id in
                try !clipboardStore.isBlobReferenced(id)
            }
        )
        let searchHealth = searchStore.databaseHealth()
        let repairMarker = try searchStore.repairNeeded()
        let shouldRepairFTS = result.missingFTSRecordCount > 0
            || repairMarker
            || searchHealth.status == .repairable
        var ftsRepairSucceeded = !shouldRepairFTS
        if shouldRepairFTS {
            do {
                let repairReport = try repairSearchIndex(for: lifecycleToken, shouldCancel: {
                    !self.isCurrentLifecycleToken(lifecycleToken)
                })
                ftsRepairSucceeded = repairReport.failedDocuments == 0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                storageDegradedReasons.insert("fts-repair-needed")
            }
        }
        return (result, ftsRepairSucceeded)
    }

}
