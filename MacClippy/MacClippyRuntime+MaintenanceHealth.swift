import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    func updateReconciliationHealth(
        _ result: MacClippyReconciliation.Result,
        for lifecycleToken: MacClippyRuntimeLifecycleToken
    ) {
        withStoreLock {
            guard isCurrentLifecycleToken(lifecycleToken) else { return }
            storageDegradedReasons.remove("storage-reconciliation-failed")
            if result.missingBlobCount == 0 {
                storageDegradedReasons.remove("missing-blob-references")
            } else {
                storageDegradedReasons.insert("missing-blob-references")
            }
            if result.failedBlobCleanupCount == 0 {
                storageDegradedReasons.remove("orphan-blob-cleanup-failed")
            } else {
                storageDegradedReasons.insert("orphan-blob-cleanup-failed")
            }
            if result.failedFTSCleanupCount == 0 {
                storageDegradedReasons.remove("orphan-fts-cleanup-failed")
            } else {
                storageDegradedReasons.insert("orphan-fts-cleanup-failed")
            }
        }
    }

    func recordReconciliationOutcome(
        _ result: MacClippyReconciliation.Result,
        ftsRepairSucceeded: Bool
    ) {
        guard !result.isEmpty else { return }
        let hasOrphans = result.orphanBlobCount > 0 || result.orphanFTSRecordCount > 0
            || result.missingFTSRecordCount > 0
        if result.failedBlobCleanupCount == 0,
           result.failedFTSCleanupCount == 0,
           hasOrphans {
            MacClippyLog.record(
                category: .storage,
                code: .reconciliationCompleted,
                operation: "startup_reconciliation",
                recoveryAction: "none",
                impact: "orphan_cleanup_completed"
            )
        }
        let missingFTSAfterRepair = !ftsRepairSucceeded && result.missingFTSRecordCount > 0
        if result.failedBlobCleanupCount > 0 || result.failedFTSCleanupCount > 0
            || missingFTSAfterRepair {
            MacClippyLog.record(
                category: .storage,
                code: .reconciliationFailed,
                operation: "startup_reconciliation_cleanup",
                recoveryAction: "export_diagnostics_and_retry",
                impact: "orphan_cleanup_incomplete"
            )
        }
        if result.missingBlobCount > 0 {
            MacClippyLog.record(
                category: .blob,
                code: .blobIntegrityFailed,
                operation: "startup_blob_integrity_check",
                recoveryAction: "restore_backup_or_delete_damaged_records",
                impact: "missing_blob_references"
            )
        }
    }

    func recordStartupHealthIfNeeded(
        health providedHealth: [String: MacClippyDatabaseHealthReport]? = nil
    ) {
        let health = providedHealth ?? withStoreLock { storageHealthLocked() }
        for databaseName in ["clipboard", "search", "pinboards", "snippets"] {
            guard let report = health[databaseName], report.status != .healthy else { continue }
            let impact = report.status == .unrecoverable
                ? "storage_unrecoverable"
                : "storage_repairable"
            MacClippyLog.record(
                category: .storage,
                code: .databaseHealthFailed,
                operation: "startup_health_check_\(databaseName)",
                recoveryAction: report.status == .unrecoverable
                    ? "restore_backup_or_reinstall_storage"
                    : "open_storage_recovery",
                impact: impact
            )
        }
    }

}
