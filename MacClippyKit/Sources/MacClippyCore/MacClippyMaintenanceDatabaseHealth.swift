import Foundation
import GRDB

public enum MacClippyDatabaseHealthStatus: String, Codable, Sendable, Equatable {
    case healthy
    case degraded
    case repairable
    case unrecoverable
}

public enum MacClippyDatabaseHealthCheckMode: Sendable, Equatable {
    case bounded
    case full
}

public struct MacClippyDatabaseHealthReport: Codable, Sendable, Equatable {
    public let status: MacClippyDatabaseHealthStatus
    /// Compatibility field retained for existing diagnostics consumers. For
    /// bounded checks it reflects a successful open/schema probe; use
    /// `fullIntegrityCheckPassed` to tell whether rows were fully scanned.
    public let quickCheckPassed: Bool
    /// `nil` means a full SQLite integrity scan was not requested. Bounded
    /// health checks skip integrity scans because SQLite's `quick_check(1)`
    /// still walks the database.
    public let fullIntegrityCheckPassed: Bool?
    /// `nil` means the foreign-key pragma was not run. Bounded health checks
    /// skip it because an empty result still requires walking all FK rows.
    public let foreignKeyCheckPerformed: Bool?
    public let foreignKeyViolationCount: Int
    public let missingTables: [String]
    public let issues: [String]

    public init(
        status: MacClippyDatabaseHealthStatus,
        quickCheckPassed: Bool,
        fullIntegrityCheckPassed: Bool? = nil,
        foreignKeyCheckPerformed: Bool? = nil,
        foreignKeyViolationCount: Int,
        missingTables: [String],
        issues: [String]
    ) {
        self.status = status
        self.quickCheckPassed = quickCheckPassed
        self.fullIntegrityCheckPassed = fullIntegrityCheckPassed
        self.foreignKeyCheckPerformed = foreignKeyCheckPerformed
        self.foreignKeyViolationCount = foreignKeyViolationCount
        self.missingTables = missingTables
        self.issues = issues
    }
}

/// Keeps its database object alive while an independent reader uses its path.
public final class MacClippyDatabaseReaderLease: @unchecked Sendable {
    private let lock = NSLock()
    private var database: MacClippyDatabase?

    init(database: MacClippyDatabase) {
        self.database = database
    }

    public func release() {
        lock.lock()
        let database = self.database
        self.database = nil
        lock.unlock()
        database?.finishIndependentReader()
    }

    deinit { release() }
}

public enum MacClippyDatabaseReaderError: Error, Sendable {
    case unavailable
    case closing
}

#if DEBUG || MACCLIPPY_TESTING
enum MacClippyMaintenanceDBHealthTestHooks {
    // All mutable callback state is protected by the holder's lock. The shared
    // reference stays immutable under Swift's complete concurrency checking.
    private final class Callbacks: @unchecked Sendable {
        let lock = NSLock()
        var integrityCheck: (@Sendable () -> Void)?
        var foreignKeyCheck: (@Sendable () -> Void)?
    }
    private static let callbacks = Callbacks()

    static func setCallbacks(
        integrityCheck: (@Sendable () -> Void)?,
        foreignKeyCheck: (@Sendable () -> Void)?
    ) {
        callbacks.lock.lock()
        callbacks.integrityCheck = integrityCheck
        callbacks.foreignKeyCheck = foreignKeyCheck
        callbacks.lock.unlock()
    }

    static func beforeIntegrityCheck() {
        callbacks.lock.lock()
        let callback = callbacks.integrityCheck
        callbacks.lock.unlock()
        callback?()
    }

    static func beforeForeignKeyCheck() {
        callbacks.lock.lock()
        let callback = callbacks.foreignKeyCheck
        callbacks.lock.unlock()
        callback?()
    }
}
#else
enum MacClippyMaintenanceDBHealthTestHooks {
    static func beforeIntegrityCheck() {}
    static func beforeForeignKeyCheck() {}
}
#endif

enum MacClippyMaintenanceDatabaseHealth {
    private struct Inspection {
        let integrityPassed: Bool?
        let integrityQueryFailed: Bool
        let foreignKeys: [Row]
        let foreignKeyQueryFailed: Bool
        let missingTablesQueryFailed: Bool
        let mode: MacClippyDatabaseHealthCheckMode
        let missingTables: [String]
    }

    static func inspect(
        _ connection: Database,
        requiredTables: Set<String>,
        mode: MacClippyDatabaseHealthCheckMode,
        shouldContinue: () -> Bool
    ) throws -> MacClippyDatabaseHealthReport {
        _ = try Int.fetchOne(connection, sql: "SELECT 1")
        let integrity = try fullIntegrityResult(connection, mode: mode, shouldContinue: shouldContinue)
        let foreignKeys = try foreignKeyResult(connection, mode: mode, shouldContinue: shouldContinue)
        let requiredTableResult = requiredTablesResult(connection, requiredTables: requiredTables)
        guard shouldContinue() else { throw CancellationError() }
        let inspection = Inspection(
            integrityPassed: integrity.passed,
            integrityQueryFailed: integrity.queryFailed,
            foreignKeys: foreignKeys.rows,
            foreignKeyQueryFailed: foreignKeys.queryFailed,
            missingTablesQueryFailed: requiredTableResult.queryFailed,
            mode: mode,
            missingTables: requiredTableResult.missingTables
        )
        let issues = healthIssues(inspection)
        let status = healthStatus(inspection)
        let boundedCheckPassed = mode == .bounded && requiredTableResult.missingTables.isEmpty
        let quickCheckPassed = integrity.passed == true || boundedCheckPassed
        return MacClippyDatabaseHealthReport(
            status: status,
            quickCheckPassed: quickCheckPassed,
            fullIntegrityCheckPassed: integrity.passed,
            foreignKeyCheckPerformed: mode == .full ? true : nil,
            foreignKeyViolationCount: foreignKeys.rows.count,
            missingTables: requiredTableResult.missingTables,
            issues: issues
        )
    }

    private static func fullIntegrityResult(
        _ connection: Database,
        mode: MacClippyDatabaseHealthCheckMode,
        shouldContinue: () -> Bool
    ) throws -> (passed: Bool?, queryFailed: Bool) {
        guard mode == .full else { return (nil, false) }
        guard shouldContinue() else { throw CancellationError() }
        do {
            MacClippyMaintenanceDBHealthTestHooks.beforeIntegrityCheck()
            let rows = try String.fetchAll(connection, sql: "PRAGMA integrity_check")
            guard shouldContinue() else { throw CancellationError() }
            return (rows.count == 1 && rows[0].lowercased() == "ok", false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return (false, true)
        }
    }

    private static func foreignKeyResult(
        _ connection: Database,
        mode: MacClippyDatabaseHealthCheckMode,
        shouldContinue: () -> Bool
    ) throws -> (rows: [Row], queryFailed: Bool) {
        guard mode == .full else { return ([], false) }
        guard shouldContinue() else { throw CancellationError() }
        do {
            MacClippyMaintenanceDBHealthTestHooks.beforeForeignKeyCheck()
            let rows = try Row.fetchAll(connection, sql: "PRAGMA foreign_key_check")
            guard shouldContinue() else { throw CancellationError() }
            return (rows, false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ([], true)
        }
    }

    private static func requiredTablesResult(
        _ connection: Database,
        requiredTables: Set<String>
    ) -> (missingTables: [String], queryFailed: Bool) {
        do {
            let existingTables = Set(try String.fetchAll(
                connection,
                sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
            ))
            return (requiredTables.subtracting(existingTables).sorted(), false)
        } catch {
            return ([], true)
        }
    }

    private static func healthIssues(_ inspection: Inspection) -> [String] {
        var issues: [String] = []
        if inspection.integrityQueryFailed || inspection.integrityPassed == false {
            issues.append("sqlite-integrity-check-failed")
        } else if inspection.integrityPassed == nil {
            issues.append("sqlite-integrity-check-skipped")
        }
        if inspection.mode == .bounded { issues.append("foreign-key-check-skipped") }
        if inspection.foreignKeyQueryFailed || inspection.missingTablesQueryFailed {
            issues.append("database-health-query-failed")
        }
        if !inspection.foreignKeys.isEmpty { issues.append("foreign-key-violations") }
        if !inspection.missingTables.isEmpty { issues.append("missing-required-tables") }
        return issues
    }

    private static func healthStatus(_ inspection: Inspection) -> MacClippyDatabaseHealthStatus {
        if inspection.integrityPassed == false
            || inspection.foreignKeyQueryFailed
            || inspection.missingTablesQueryFailed
            || !inspection.missingTables.isEmpty {
            return .unrecoverable
        }
        return inspection.foreignKeys.isEmpty ? .healthy : .repairable
    }
}
