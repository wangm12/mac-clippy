import Foundation

import MacClippyCore

extension MacClippyRuntime {
    func storageHealthLocked() -> [String: MacClippyDatabaseHealthReport] {
        var health = [
            "clipboard": clipboardStore.databaseHealth(),
            "search": searchStore.databaseHealth(),
            "pinboards": pinboardStore.databaseHealth(),
            "snippets": snippetStore.databaseHealth()
        ]
        if storageDegradedReasons.contains("missing-blob-references"),
           let clipboard = health["clipboard"] {
            let issues = Array(Set(clipboard.issues + ["missing-blob-references"])).sorted()
            let status: MacClippyDatabaseHealthStatus = clipboard.status == .unrecoverable
                ? .unrecoverable
                : .degraded
            health["clipboard"] = MacClippyDatabaseHealthReport(
                status: status,
                quickCheckPassed: clipboard.quickCheckPassed,
                foreignKeyViolationCount: clipboard.foreignKeyViolationCount,
                missingTables: clipboard.missingTables,
                issues: issues
            )
        }
        if storageDegradedReasons.contains("storage-reconciliation-failed")
            || storageDegradedReasons.contains("orphan-blob-cleanup-failed") {
            if let clipboard = health["clipboard"] {
                var reconciliationIssues: [String] = []
                if storageDegradedReasons.contains("storage-reconciliation-failed") {
                    reconciliationIssues.append("storage-reconciliation-failed")
                }
                if storageDegradedReasons.contains("orphan-blob-cleanup-failed") {
                    reconciliationIssues.append("orphan-blob-cleanup-failed")
                }
                let issues = Array(Set(clipboard.issues + reconciliationIssues)).sorted()
                health["clipboard"] = MacClippyDatabaseHealthReport(
                    status: clipboard.status == .unrecoverable ? .unrecoverable : .degraded,
                    quickCheckPassed: clipboard.quickCheckPassed,
                    foreignKeyViolationCount: clipboard.foreignKeyViolationCount,
                    missingTables: clipboard.missingTables,
                    issues: issues
                )
            }
        }
        if storageDegradedReasons.contains("orphan-fts-cleanup-failed"),
           let search = health["search"] {
            let issues = Array(Set(search.issues + ["orphan-fts-cleanup-failed"])).sorted()
            health["search"] = MacClippyDatabaseHealthReport(
                status: search.status == .unrecoverable ? .unrecoverable : .degraded,
                quickCheckPassed: search.quickCheckPassed,
                foreignKeyViolationCount: search.foreignKeyViolationCount,
                missingTables: search.missingTables,
                issues: issues
            )
        }
        let ftsRepairNeeded: Bool
        do {
            if storageDegradedReasons.contains("fts-repair-needed") {
                ftsRepairNeeded = true
            } else {
                ftsRepairNeeded = try searchStore.repairNeeded()
            }
        } catch {
            if let search = health["search"] {
                let issues = Array(Set(search.issues + ["search-state-query-failed"])).sorted()
                health["search"] = MacClippyDatabaseHealthReport(
                    status: .unrecoverable,
                    quickCheckPassed: false,
                    foreignKeyViolationCount: search.foreignKeyViolationCount,
                    missingTables: search.missingTables,
                    issues: issues
                )
            }
            return health
        }
        guard ftsRepairNeeded,
              let search = health["search"] else {
            return health
        }
        let issues = Array(Set(search.issues + ["fts-repair-needed"])).sorted()
        let status: MacClippyDatabaseHealthStatus = search.status == .unrecoverable
            ? .unrecoverable
            : .repairable
        health["search"] = MacClippyDatabaseHealthReport(
            status: status,
            quickCheckPassed: search.quickCheckPassed,
            foreignKeyViolationCount: search.foreignKeyViolationCount,
            missingTables: search.missingTables,
            issues: issues
        )
        return health
    }

    func isCorruptStoredRecord(_ error: Error) -> Bool {
        if error is DecodingError {
            return true
        }
        if let storeError = error as? MacClippyStoreError {
            if case .invalidStoredRecord = storeError { return true }
        }
        if let cipherError = error as? MacClippyCipherError {
            switch cipherError {
            case .invalidEnvelope:
                return true
            case .openFailed, .sealFailed:
                return false
            }
        }
        if let blobError = error as? MacClippyBlobError {
            switch blobError {
            case .invalidIdentifier, .missingBlob:
                return true
            case .payloadTooLarge:
                return false
            }
        }
        return false
    }

    func recordCorruptStoredRecord(operation: String) {
        MacClippyLog.record(
            category: .storage,
            code: .corruptStoredRecord,
            operation: operation,
            recoveryAction: "repair_or_delete_corrupt_record",
            impact: "record_skipped"
        )
    }
}
