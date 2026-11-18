import Foundation

extension MacClippySearchStore {
    private static let requiredHealthTables: Set<String> = [
        "macclippy_search_index",
        "macclippy_search_keys",
        "macclippy_search_state",
        "grdb_migrations"
    ]

    public func databaseHealth(
        mode: MacClippyDatabaseHealthCheckMode = .bounded
    ) -> MacClippyDatabaseHealthReport {
        let base = database.healthCheck(requiredTables: Self.requiredHealthTables, mode: mode)
        guard base.status == .healthy else { return base }

        let repairIsNeeded: Bool
        do {
            repairIsNeeded = try repairNeeded()
        } catch {
            return failedSearchHealth(base: base, issue: "fts-repair-state-query-failed")
        }

        if mode == .bounded {
            return boundedSearchHealth(base: base, repairIsNeeded: repairIsNeeded)
        }
        return fullSearchHealth(base: base, repairIsNeeded: repairIsNeeded)
    }

    private func boundedSearchHealth(
        base: MacClippyDatabaseHealthReport,
        repairIsNeeded: Bool
    ) -> MacClippyDatabaseHealthReport {
        var issues = base.issues + ["fts-projection-integrity-not-checked"]
        if repairIsNeeded { issues.append("fts-repair-needed") }
        return MacClippyDatabaseHealthReport(
            status: repairIsNeeded ? .repairable : .healthy,
            quickCheckPassed: base.quickCheckPassed,
            fullIntegrityCheckPassed: base.fullIntegrityCheckPassed,
            foreignKeyCheckPerformed: base.foreignKeyCheckPerformed,
            foreignKeyViolationCount: base.foreignKeyViolationCount,
            missingTables: base.missingTables,
            issues: issues
        )
    }

    private func fullSearchHealth(
        base: MacClippyDatabaseHealthReport,
        repairIsNeeded: Bool
    ) -> MacClippyDatabaseHealthReport {
        let projectionIssues: [String]
        do {
            projectionIssues = try ftsIntegrityIssues()
        } catch {
            return failedSearchHealth(base: base, issue: "fts-integrity-query-failed")
        }
        var issues = base.issues + projectionIssues
        if repairIsNeeded { issues.append("fts-repair-needed") }
        guard !issues.isEmpty else { return base }
        return MacClippyDatabaseHealthReport(
            status: .repairable,
            quickCheckPassed: base.quickCheckPassed,
            fullIntegrityCheckPassed: base.fullIntegrityCheckPassed,
            foreignKeyCheckPerformed: base.foreignKeyCheckPerformed,
            foreignKeyViolationCount: base.foreignKeyViolationCount,
            missingTables: base.missingTables,
            issues: issues
        )
    }

    private func failedSearchHealth(
        base: MacClippyDatabaseHealthReport,
        issue: String
    ) -> MacClippyDatabaseHealthReport {
        MacClippyDatabaseHealthReport(
            status: .unrecoverable,
            quickCheckPassed: false,
            fullIntegrityCheckPassed: base.fullIntegrityCheckPassed,
            foreignKeyCheckPerformed: base.foreignKeyCheckPerformed,
            foreignKeyViolationCount: base.foreignKeyViolationCount,
            missingTables: base.missingTables,
            issues: base.issues + [issue]
        )
    }
}
