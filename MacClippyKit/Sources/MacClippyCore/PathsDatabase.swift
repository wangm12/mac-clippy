import Foundation
import GRDB

public struct MacClippyPaths: Sendable {
    public let rootURL: URL
    public let databasesURL: URL
    public let blobsURL: URL
    public let thumbnailsURL: URL
    public let clipboardDatabaseURL: URL
    public let searchDatabaseURL: URL
    public let pinboardDatabaseURL: URL
    public let snippetDatabaseURL: URL
    public let diagnosticsJournalURL: URL

    public init(rootURL: URL? = nil, fileManager: FileManager = .default) throws {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let root = rootURL ?? applicationSupport.appendingPathComponent("MacClippy", isDirectory: true)
        self.rootURL = root.standardizedFileURL
        databasesURL = root.appendingPathComponent("databases", isDirectory: true)
        blobsURL = root.appendingPathComponent("blobs", isDirectory: true)
        thumbnailsURL = root.appendingPathComponent(MacClippyThumbnailCachePolicy.directoryName, isDirectory: true)
        clipboardDatabaseURL = databasesURL.appendingPathComponent("clipboard.sqlite")
        searchDatabaseURL = databasesURL.appendingPathComponent("search.sqlite")
        pinboardDatabaseURL = databasesURL.appendingPathComponent("pinboards.sqlite")
        snippetDatabaseURL = databasesURL.appendingPathComponent("snippets.sqlite")
        diagnosticsJournalURL = root.appendingPathComponent("diagnostics.jsonl")
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: databasesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: blobsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
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

public final class MacClippyDatabase {
    public let url: URL
    public let queue: DatabaseQueue
    private let healthReaderCondition = NSCondition()
    private var activeIndependentReaderCount = 0
    private var refusesIndependentReaders = false
    private var closedForReplacement = false

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

    public init(
        url: URL,
        readOnly: Bool = false,
        migrations: [MacClippyDatabaseMigration] = []
    ) throws {
        self.url = url
        var configuration = Configuration()
        configuration.readonly = readOnly
        if !readOnly {
            configuration.prepareDatabase { database in
                try database.execute(sql: "PRAGMA journal_mode = WAL")
                try database.execute(sql: "PRAGMA synchronous = NORMAL")
                try database.execute(sql: "PRAGMA foreign_keys = ON")
                try database.execute(sql: "PRAGMA busy_timeout = 5000")
            }
        }
        let isMemory = url.path == ":memory:" || url.lastPathComponent == ":memory:"
        if !isMemory && !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        queue = try isMemory
            ? DatabaseQueue(configuration: configuration)
            : DatabaseQueue(path: url.path, configuration: configuration)
        if !readOnly { try migrate(migrations) }
    }

    public func migrate(_ migrations: [MacClippyDatabaseMigration]) throws {
        guard !migrations.isEmpty else { return }
        var migrator = DatabaseMigrator()
        for migration in migrations {
            migrator.registerMigration(migration.identifier, migrate: migration.migrate)
        }
        try migrator.migrate(queue)
    }

    /// Runs a read-only schema probe or explicit full integrity scan. The
    /// report contains no row values or clipboard content.
    public func healthCheck(
        requiredTables: Set<String> = [],
        mode: MacClippyDatabaseHealthCheckMode = .bounded,
        shouldContinue: () -> Bool = { true }
    ) -> MacClippyDatabaseHealthReport {
        var completedReport: MacClippyDatabaseHealthReport?
        do {
            return try withIndependentReadOnlyConnection { connection in
                guard shouldContinue() else { throw CancellationError() }
                let report = try MacClippyMaintenanceDatabaseHealth.inspect(
                    connection,
                    requiredTables: requiredTables,
                    mode: mode,
                    shouldContinue: shouldContinue
                )
                completedReport = report
                return report
            }
        } catch is CancellationError {
            return healthCancelledReport()
        } catch MacClippyDatabaseReaderError.closing {
            return healthCancelledReport()
        } catch {
            if mode == .full, let completedReport {
                return completedReport
            }
            // Do not surface SQLite's raw message: it can contain a local
            // path. A failed integrity query is itself an unrecoverable
            // health result until a backup/restore path is attempted.
            return healthUnavailableReport()
        }
    }

    /// Runs a caller-supplied inspection on a separate read-only connection
    /// and reserves the database against replacement for the closure's full
    /// lifetime. Callers should use this for exhaustive health work outside
    /// the Runtime store lock.
    public func withIndependentReadOnlyConnection<T>(
        _ body: (Database) throws -> T
    ) throws -> T {
        let readerLease = try beginIndependentReader()
        defer { readerLease.release() }

        let writerIsOpen = try queue.read { connection in
            connection.sqliteConnection != nil
        }
        guard writerIsOpen else { throw MacClippyDatabaseReaderError.unavailable }
        guard !isInMemoryDatabase else { return try queue.read(body) }

        var configuration = Configuration()
        configuration.readonly = true
        let reader = try DatabaseQueue(path: url.path, configuration: configuration)
        defer {
            do {
                try reader.close()
            } catch {
                MacClippyLog.record(
                    category: .storage,
                    code: .databaseHealthFailed,
                    operation: "health_reader_close",
                    recoveryAction: "retry_on_next_launch",
                    impact: "database_health_reader_close_failed"
                )
            }
        }
        return try reader.read(body)
    }

    /// Opens a pinned backup read snapshot while holding a reader reservation
    /// against `closeForReplacement()`. Snapshot copying can then continue
    /// after the Runtime releases its global store lock.
    public func beginBackupReadSnapshot(name: String) throws -> MacClippyBackupReadSnapshot {
        let readerLease: MacClippyDatabaseReaderLease
        do {
            readerLease = try beginIndependentReader()
        } catch {
            throw MacClippyBackupError.databaseCopyFailed(name)
        }
        do {
            let writerIsOpen = try queue.read { connection in
                connection.sqliteConnection != nil
            }
            guard writerIsOpen else { throw MacClippyBackupError.databaseCopyFailed(name) }
            if isInMemoryDatabase {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "MacClippyBackupReadSnapshot-\(UUID().uuidString)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let snapshotURL = directory.appendingPathComponent("\(name).sqlite")
                do {
                    try MacClippyBackup.backup(queue, to: snapshotURL)
                    return try MacClippyBackupReadSnapshot(
                        name: name,
                        databaseURL: snapshotURL,
                        databaseLease: readerLease,
                        temporarySnapshotURL: directory
                    )
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
            }
            return try MacClippyBackupReadSnapshot(name: name, databaseURL: url, databaseLease: readerLease)
        } catch {
            readerLease.release()
            throw error
        }
    }

    /// Stops new independent readers and waits for active readers before the
    /// Runtime replaces this database's files. Direct callers of
    /// `queue.close()` remain supported; later health queries fail their
    /// writer-open check instead of reopening the path.
    public func closeForReplacement() throws {
        healthReaderCondition.lock()
        while refusesIndependentReaders && !closedForReplacement {
            healthReaderCondition.wait()
        }
        guard !closedForReplacement else {
            healthReaderCondition.unlock()
            return
        }
        refusesIndependentReaders = true
        while activeIndependentReaderCount > 0 {
            healthReaderCondition.wait()
        }
        healthReaderCondition.unlock()
        do {
            try queue.close()
            healthReaderCondition.lock()
            closedForReplacement = true
            refusesIndependentReaders = true
            healthReaderCondition.broadcast()
            healthReaderCondition.unlock()
        } catch {
            healthReaderCondition.lock()
            refusesIndependentReaders = false
            healthReaderCondition.broadcast()
            healthReaderCondition.unlock()
            throw error
        }
    }

    private func beginIndependentReader() throws -> MacClippyDatabaseReaderLease {
        healthReaderCondition.lock()
        defer { healthReaderCondition.unlock() }
        guard !refusesIndependentReaders else {
            throw closedForReplacement ? MacClippyDatabaseReaderError.unavailable : .closing
        }
        activeIndependentReaderCount += 1
        return MacClippyDatabaseReaderLease(database: self)
    }

    func finishIndependentReader() {
        healthReaderCondition.lock()
        activeIndependentReaderCount = max(0, activeIndependentReaderCount - 1)
        healthReaderCondition.broadcast()
        healthReaderCondition.unlock()
    }

    private func healthUnavailableReport() -> MacClippyDatabaseHealthReport {
        MacClippyDatabaseHealthReport(
            status: .unrecoverable,
            quickCheckPassed: false,
            // If the connection could not be opened or the initial probe
            // failed, the full scan did not run. Failed scan queries return a
            // completed inspection report with `false` instead.
            fullIntegrityCheckPassed: nil,
            foreignKeyCheckPerformed: nil,
            foreignKeyViolationCount: 0,
            missingTables: [],
            issues: ["database-health-query-failed"]
        )
    }

    private func healthCancelledReport() -> MacClippyDatabaseHealthReport {
        MacClippyDatabaseHealthReport(
            status: .degraded,
            quickCheckPassed: false,
            foreignKeyViolationCount: 0,
            missingTables: [],
            issues: ["database-health-check-cancelled"]
        )
    }

    private var isInMemoryDatabase: Bool {
        url.path == ":memory:" || url.lastPathComponent == ":memory:"
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
