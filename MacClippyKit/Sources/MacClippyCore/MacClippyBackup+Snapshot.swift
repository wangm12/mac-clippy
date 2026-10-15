import Foundation
import SQLite3

/// A pinned, read-only SQLite view used to copy one store after the runtime's
/// short cross-store commit barrier has been released.
public final class MacClippyBackupReadSnapshot: @unchecked Sendable {
    public let name: String
    private let lock = NSLock()
    private var connection: OpaquePointer?
    private var databaseLease: MacClippyDatabaseReaderLease?
    private var temporarySnapshotURL: URL?

    init(
        name: String,
        databaseURL: URL,
        databaseLease: MacClippyDatabaseReaderLease,
        temporarySnapshotURL: URL? = nil
    ) throws {
        self.name = name
        self.databaseLease = databaseLease
        self.temporarySnapshotURL = temporarySnapshotURL
        guard databaseURL.path != ":memory:", databaseURL.lastPathComponent != ":memory:" else {
            throw MacClippyBackupError.databaseCopyFailed(name)
        }
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw MacClippyBackupError.databaseCopyFailed(name)
        }
        sqlite3_busy_timeout(database, 5_000)
        guard Self.execute("BEGIN", on: database), Self.pinReadSnapshot(on: database) else {
            sqlite3_close_v2(database)
            throw MacClippyBackupError.databaseCopyFailed(name)
        }
        connection = database
    }

    deinit { close() }

    public func copy(to destinationURL: URL, shouldContinue: () -> Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let source = connection, shouldContinue() else { throw CancellationError() }
        let destination = try Self.openDestination(at: destinationURL, name: name)
        var destinationClosed = false
        defer {
            if !destinationClosed { sqlite3_close_v2(destination) }
        }
        try Self.copyDatabase(
            source: source,
            destination: destination,
            name: name,
            shouldContinue: shouldContinue
        )
        destinationClosed = sqlite3_close_v2(destination) == SQLITE_OK
        guard destinationClosed else {
            throw MacClippyBackupError.databaseCopyFailed(name)
        }
        // sqlite3_backup copies the source header, including WAL journal mode.
        // Normalize only after closing the raw destination handle so the
        // portable file has no dependency on transient sidecars.
        try MacClippyBackup.normalize(destinationURL)
    }

    private static func openDestination(at url: URL, name: String) throws -> OpaquePointer {
        var destination: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let destination else {
            if let destination { sqlite3_close_v2(destination) }
            throw MacClippyBackupError.databaseCopyFailed(name)
        }
        guard execute("PRAGMA journal_mode = DELETE", on: destination),
              execute("PRAGMA synchronous = FULL", on: destination) else {
            sqlite3_close_v2(destination)
            throw MacClippyBackupError.databaseCopyFailed(name)
        }
        return destination
    }

    private static func copyDatabase(
        source: OpaquePointer,
        destination: OpaquePointer,
        name: String,
        shouldContinue: () -> Bool
    ) throws {
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw MacClippyBackupError.databaseCopyFailed(name)
        }
        var backupFinished = false
        defer {
            if !backupFinished { sqlite3_backup_finish(backup) }
        }

        try copyPages(backup, name: name, shouldContinue: shouldContinue)
        let finishResult = sqlite3_backup_finish(backup)
        backupFinished = true
        guard finishResult == SQLITE_OK else {
            throw MacClippyBackupError.databaseCopyFailed(name)
        }
    }

    private static func copyPages(
        _ backup: OpaquePointer,
        name: String,
        shouldContinue: () -> Bool
    ) throws {
        while shouldContinue() {
            let result = sqlite3_backup_step(backup, 128)
            if result == SQLITE_DONE { return }
            if result == SQLITE_OK { continue }
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                sqlite3_sleep(10)
                continue
            }
            throw MacClippyBackupError.databaseCopyFailed(name)
        }
        throw CancellationError()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let connection {
            self.connection = nil
            sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
            sqlite3_close_v2(connection)
        }
        databaseLease?.release()
        databaseLease = nil
        if let temporarySnapshotURL {
            self.temporarySnapshotURL = nil
            try? FileManager.default.removeItem(at: temporarySnapshotURL)
        }
    }

    private static func pinReadSnapshot(on database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT name FROM sqlite_master LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        return result == SQLITE_ROW || result == SQLITE_DONE
    }

    private static func execute(_ sql: String, on database: OpaquePointer) -> Bool {
        sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
    }
}
