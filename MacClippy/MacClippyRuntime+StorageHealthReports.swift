import Foundation

import MacClippyCore

private struct MacClippyRuntimeStorageHealthState {
    let reasons: Set<String>
    let searchRepairNeeded: Bool?
}

extension MacClippyRuntime {
    func storageHealthLocked() -> [String: MacClippyDatabaseHealthReport] {
        storageHealthReports(for: storageHealthStateLocked(), mode: .bounded)
    }

    func storageHealth(
        mode: MacClippyDatabaseHealthCheckMode = .bounded
    ) -> [String: MacClippyDatabaseHealthReport] {
        let state = withStoreLock { storageHealthStateLocked() }
        return storageHealthReports(for: state, mode: mode)
    }

    private func storageHealthStateLocked() -> MacClippyRuntimeStorageHealthState {
        let knownReasons = [
            "missing-blob-references",
            "storage-reconciliation-failed",
            "orphan-blob-cleanup-failed",
            "orphan-fts-cleanup-failed",
            "fts-repair-needed"
        ]
        var reasons = Set(knownReasons.filter { storageDegradedReasons.contains($0) })
        let repairNeeded: Bool?
        if reasons.contains("fts-repair-needed") {
            repairNeeded = true
        } else {
            do {
                repairNeeded = try searchStore.repairNeeded()
                if repairNeeded == true { reasons.insert("fts-repair-needed") }
            } catch {
                repairNeeded = nil
            }
        }
        return MacClippyRuntimeStorageHealthState(reasons: reasons, searchRepairNeeded: repairNeeded)
    }

    private func storageHealthReports(
        for state: MacClippyRuntimeStorageHealthState,
        mode: MacClippyDatabaseHealthCheckMode
    ) -> [String: MacClippyDatabaseHealthReport] {
        var reports = [
            "clipboard": clipboardStore.databaseHealth(mode: mode),
            "search": searchStore.databaseHealth(mode: mode),
            "pinboards": pinboardStore.databaseHealth(mode: mode),
            "snippets": snippetStore.databaseHealth(mode: mode)
        ]
        applyClipboardDegradation(to: &reports, reasons: state.reasons)
        applySearchCleanupDegradation(to: &reports, reasons: state.reasons)
        applySearchRepairState(to: &reports, repairNeeded: state.searchRepairNeeded)
        return reports
    }

    private func applyClipboardDegradation(
        to reports: inout [String: MacClippyDatabaseHealthReport],
        reasons: Set<String>
    ) {
        guard let clipboard = reports["clipboard"] else { return }
        var issues: [String] = []
        if reasons.contains("missing-blob-references") { issues.append("missing-blob-references") }
        if reasons.contains("storage-reconciliation-failed") { issues.append("storage-reconciliation-failed") }
        if reasons.contains("orphan-blob-cleanup-failed") { issues.append("orphan-blob-cleanup-failed") }
        guard !issues.isEmpty else { return }
        reports["clipboard"] = addingIssues(
            issues,
            to: clipboard,
            status: clipboard.status == .unrecoverable ? .unrecoverable : .degraded
        )
    }

    private func applySearchCleanupDegradation(
        to reports: inout [String: MacClippyDatabaseHealthReport],
        reasons: Set<String>
    ) {
        guard reasons.contains("orphan-fts-cleanup-failed"),
              let search = reports["search"] else {
            return
        }
        reports["search"] = addingIssues(
            ["orphan-fts-cleanup-failed"],
            to: search,
            status: search.status == .unrecoverable ? .unrecoverable : .degraded
        )
    }

    private func applySearchRepairState(
        to reports: inout [String: MacClippyDatabaseHealthReport],
        repairNeeded: Bool?
    ) {
        guard let repairNeeded else {
            if let search = reports["search"] {
                reports["search"] = addingIssues(
                    ["search-state-query-failed"],
                    to: search,
                    status: search.status == .unrecoverable ? .unrecoverable : .degraded
                )
            }
            return
        }
        guard repairNeeded, let search = reports["search"] else { return }
        reports["search"] = addingIssues(
            ["fts-repair-needed"],
            to: search,
            status: search.status == .unrecoverable ? .unrecoverable : .repairable
        )
    }

    private func addingIssues(
        _ newIssues: [String],
        to report: MacClippyDatabaseHealthReport,
        status: MacClippyDatabaseHealthStatus
    ) -> MacClippyDatabaseHealthReport {
        MacClippyDatabaseHealthReport(
            status: status,
            quickCheckPassed: report.quickCheckPassed,
            fullIntegrityCheckPassed: report.fullIntegrityCheckPassed,
            foreignKeyCheckPerformed: report.foreignKeyCheckPerformed,
            foreignKeyViolationCount: report.foreignKeyViolationCount,
            missingTables: report.missingTables,
            issues: Array(Set(report.issues + newIssues)).sorted()
        )
    }
}
