import Foundation
import GRDB

public struct MacClippyPaths: Sendable {
    public let rootURL: URL
    public let databasesURL: URL
    public let blobsURL: URL
    public let clipboardDatabaseURL: URL
    public let searchDatabaseURL: URL
    public let pinboardDatabaseURL: URL
    public let snippetDatabaseURL: URL

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let root = rootURL ?? applicationSupport.appendingPathComponent("MacClippy", isDirectory: true)
        self.rootURL = root.standardizedFileURL
        databasesURL = root.appendingPathComponent("databases", isDirectory: true)
        blobsURL = root.appendingPathComponent("blobs", isDirectory: true)
        clipboardDatabaseURL = databasesURL.appendingPathComponent("clipboard.sqlite")
        searchDatabaseURL = databasesURL.appendingPathComponent("search.sqlite")
        pinboardDatabaseURL = databasesURL.appendingPathComponent("pinboards.sqlite")
        snippetDatabaseURL = databasesURL.appendingPathComponent("snippets.sqlite")
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: databasesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: blobsURL, withIntermediateDirectories: true)
    }
}

public struct MacClippyDatabaseMigration: Sendable {
    public let identifier: String
    public let migrate: @Sendable (GRDB.Database) throws -> Void

    public init(identifier: String, migrate: @escaping @Sendable (GRDB.Database) throws -> Void) {
        self.identifier = identifier
        self.migrate = migrate
    }
}

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
    public let quickCheckPassed: Bool
    public let foreignKeyViolationCount: Int
    public let missingTables: [String]
    public let issues: [String]

    public init(
        status: MacClippyDatabaseHealthStatus,
        quickCheckPassed: Bool,
        foreignKeyViolationCount: Int,
        missingTables: [String],
        issues: [String]
    ) {
        self.status = status
        self.quickCheckPassed = quickCheckPassed
        self.foreignKeyViolationCount = foreignKeyViolationCount
        self.missingTables = missingTables
        self.issues = issues
    }
}

public final class MacClippyDatabase {
    public let queue: DatabaseQueue

    deinit {
        // GRDB's DatabaseQueue does not close its writer connection from
        // deinit. Close explicitly so AppKit/test teardown cannot unlink a
        // WAL database while SQLite still owns its file descriptors.
        do {
            try queue.close()
        } catch {
            MacClippyLog.record(
                category: .storage,
                code: .databaseHealthFailed,
                operation: "database_close",
                recoveryAction: "retry_on_next_launch",
                impact: "database_close_failed"
            )
        }
    }

    public init(url: URL, migrations: [MacClippyDatabaseMigration] = []) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA journal_mode = WAL")
            try database.execute(sql: "PRAGMA synchronous = NORMAL")
            try database.execute(sql: "PRAGMA foreign_keys = ON")
            try database.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        let isMemory = url.path == ":memory:" || url.lastPathComponent == ":memory:"
        if !isMemory {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        queue = try isMemory
            ? DatabaseQueue(configuration: configuration)
            : DatabaseQueue(path: url.path, configuration: configuration)
        try migrate(migrations)
    }

    public func migrate(_ migrations: [MacClippyDatabaseMigration]) throws {
        guard !migrations.isEmpty else { return }
        var migrator = DatabaseMigrator()
        for migration in migrations {
            migrator.registerMigration(migration.identifier, migrate: migration.migrate)
        }
        try migrator.migrate(queue)
    }

    /// Runs a bounded, read-only integrity check. The report deliberately
    /// contains only schema/integrity facts, never row values or clipboard
    /// content, so it can safely be used by diagnostics and recovery UI.
    public func healthCheck(
        requiredTables: Set<String> = [],
        mode: MacClippyDatabaseHealthCheckMode = .bounded
    ) -> MacClippyDatabaseHealthReport {
        do {
            return try queue.read { connection in
                let quickCheckSQL = mode == .bounded ? "PRAGMA quick_check(1)" : "PRAGMA quick_check"
                let quickCheck = try String.fetchAll(connection, sql: quickCheckSQL)
                let foreignKeyViolations: [Row]
                if mode == .bounded {
                    // The table-valued pragma lets the UI/startup check stop
                    // after a small sample. Backup validation explicitly uses
                    // .full so it still proves the complete foreign-key set.
                    do {
                        foreignKeyViolations = try Row.fetchAll(
                            connection,
                            sql: "SELECT * FROM pragma_foreign_key_check LIMIT 64"
                        )
                    } catch {
                        // Older SQLite builds do not expose table-valued
                        // pragmas. Keep the check correct on those builds;
                        // the app's supported macOS builds use the bounded
                        // form above.
                        foreignKeyViolations = try Row.fetchAll(connection, sql: "PRAGMA foreign_key_check")
                    }
                } else {
                    foreignKeyViolations = try Row.fetchAll(connection, sql: "PRAGMA foreign_key_check")
                }
                let existingTables = Set(try String.fetchAll(
                    connection,
                    sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')"
                ))
                let missingTables = requiredTables.subtracting(existingTables).sorted()
                let quickCheckPassed = quickCheck.count == 1 && quickCheck[0].lowercased() == "ok"
                var issues: [String] = []
                if !quickCheckPassed { issues.append("sqlite-quick-check-failed") }
                if !foreignKeyViolations.isEmpty { issues.append("foreign-key-violations") }
                if mode == .bounded, foreignKeyViolations.count == 64 {
                    issues.append("foreign-key-violations-truncated")
                }
                if !missingTables.isEmpty { issues.append("missing-required-tables") }

                let status: MacClippyDatabaseHealthStatus
                if !quickCheckPassed || !missingTables.isEmpty {
                    status = .unrecoverable
                } else if !foreignKeyViolations.isEmpty {
                    status = .repairable
                } else {
                    status = .healthy
                }
                return MacClippyDatabaseHealthReport(
                    status: status,
                    quickCheckPassed: quickCheckPassed,
                    foreignKeyViolationCount: foreignKeyViolations.count,
                    missingTables: missingTables,
                    issues: issues
                )
            }
        } catch {
            // Do not surface SQLite's raw message: it can contain a local
            // path. A failed integrity query is itself an unrecoverable
            // health result until a backup/restore path is attempted.
            return MacClippyDatabaseHealthReport(
                status: .unrecoverable,
                quickCheckPassed: false,
                foreignKeyViolationCount: 0,
                missingTables: [],
                issues: ["database-health-query-failed"]
            )
        }
    }

    public func tableRowCount(_ table: String) throws -> Int64? {
        guard table.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" ) }) else { return nil }
        return try queue.read { connection in
            try Int64.fetchOne(connection, sql: "SELECT COUNT(*) FROM \(table)")
        }
    }

    public convenience init(inMemory: Bool) throws {
        try self.init(url: URL(fileURLWithPath: inMemory ? ":memory:" : "macclippy.sqlite"))
    }
}
