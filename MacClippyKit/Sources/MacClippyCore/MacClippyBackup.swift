import CryptoKit
import Foundation
import GRDB

public struct MacClippyBackupSource {
    public let name: String
    public let database: MacClippyDatabase

    public init(name: String, database: MacClippyDatabase) {
        self.name = name
        self.database = database
    }
}

/// A sendable capability for backup operations that need to authenticate with
/// this installation's key. The key itself is not exposed to app callers.
public struct MacClippyBackupKeySource: Sendable {
    let key: SymmetricKey
}

public extension MacClippyClipboardStore {
    var backupKeySource: MacClippyBackupKeySource {
        MacClippyBackupKeySource(key: key)
    }
}

public struct MacClippyBackupManifest: Codable, Sendable, Equatable {
    public struct FileEntry: Codable, Sendable, Equatable {
        public let relativePath: String
        public let byteCount: Int64
        public let sha256: String

        public init(relativePath: String, byteCount: Int64, sha256: String) {
            self.relativePath = relativePath
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public let formatVersion: Int
    public let createdAt: Date
    public let databaseNames: [String]
    public let files: [FileEntry]
    /// An authenticated marker proving that a backup was created with the
    /// same device key used by this installation. Older format-1 backups do
    /// not contain this value and are verified by opening their encrypted
    /// payloads before restore.
    public let keyCheck: String?

    public init(
        formatVersion: Int,
        createdAt: Date,
        databaseNames: [String],
        files: [FileEntry],
        keyCheck: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.databaseNames = databaseNames
        self.files = files
        self.keyCheck = keyCheck
    }
}

public struct MacClippyBackupValidation: Sendable, Equatable {
    public let manifest: MacClippyBackupManifest
    public let databaseHealth: [String: MacClippyDatabaseHealthReport]
    public let databaseRowCounts: [String: Int64]
    public let keyCompatible: Bool

    public init(
        manifest: MacClippyBackupManifest,
        databaseHealth: [String: MacClippyDatabaseHealthReport],
        databaseRowCounts: [String: Int64],
        keyCompatible: Bool = false
    ) {
        self.manifest = manifest
        self.databaseHealth = databaseHealth
        self.databaseRowCounts = databaseRowCounts
        self.keyCompatible = keyCompatible
    }
}

public enum MacClippyBackupError: Error, Equatable {
    case destinationExists
    case invalidManifest
    case missingComponent(String)
    case checksumMismatch(String)
    case keyRequired
    case keyMismatch
    case keyCompatibilityUnproven
    case databaseCopyFailed(String)
    case restoreInterrupted
}

/// Creates and validates a portable local snapshot. Database files are copied
/// through SQLite's online backup API, not with FileManager, so WAL contents
/// are included consistently. Callers pin all database snapshots during one
/// application commit barrier, then run copying and validation without it.
public enum MacClippyBackup {
    public static let manifestFileName = "manifest.json"
    public static let currentFormatVersion = 2
    static let legacyFormatVersion = 1
    static let keyCheckSentinel = Data("MacClippy backup key check v1".utf8)
    static let restoreJournalFileName = ".macclippy-restore-journal.json"

    enum RestoreFaultPoint: Equatable {
        case beforeInstall(String)
        case afterInstall(String)
        case beforeCommit
        case afterRollback(String)
        case afterRollbackCommit
        case beforeTransactionCleanup
        case afterTransactionCleanup
        case beforeJournalCleanup
    }

    struct RestoreJournal: Codable {
        let transactionDirectory: String
        let hadOriginalComponent: [String: Bool]
        var finalized: Bool
    }

    static let liveComponents = ["databases", "blobs", MacClippyThumbnailCachePolicy.directoryName]

    static func ensureContinues(_ shouldContinue: () -> Bool) throws {
        guard shouldContinue() else { throw CancellationError() }
    }

    /// Opens and pins all source read transactions. Runtime callers invoke
    /// this while holding their cross-store commit barrier, then release the
    /// barrier before copying any database pages or blobs.
    public static func beginReadSnapshots(
        sources: [MacClippyBackupSource]
    ) throws -> [MacClippyBackupReadSnapshot] {
        try validateNames(sources.map(\.name))
        var snapshots: [MacClippyBackupReadSnapshot] = []
        snapshots.reserveCapacity(sources.count)
        for source in sources {
            snapshots.append(try source.database.beginBackupReadSnapshot(name: source.name))
        }
        return snapshots
    }

    @discardableResult
    public static func create(
        sources: [MacClippyBackupSource],
        blobsURL: URL,
        keySource: MacClippyBackupKeySource,
        at destinationURL: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> MacClippyBackupManifest {
        let snapshots = try beginReadSnapshots(sources: sources)
        return try create(
            snapshots: snapshots,
            blobsURL: blobsURL,
            keySource: keySource,
            at: destinationURL,
            now: now,
            fileManager: fileManager
        )
    }

    @discardableResult
    static func create(
        sources: [MacClippyBackupSource],
        blobsURL: URL,
        deviceKey: SymmetricKey,
        at destinationURL: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> MacClippyBackupManifest {
        let snapshots = try beginReadSnapshots(sources: sources)
        return try create(
            snapshots: snapshots,
            blobsURL: blobsURL,
            keySource: MacClippyBackupKeySource(key: deviceKey),
            at: destinationURL,
            now: now,
            fileManager: fileManager
        )
    }

    public static func validate(
        at snapshotURL: URL,
        keySource: MacClippyBackupKeySource? = nil,
        fileManager: FileManager = .default
    ) throws -> MacClippyBackupValidation {
        try validate(at: snapshotURL, deviceKey: keySource?.key, fileManager: fileManager)
    }

    static func validate(
        at snapshotURL: URL,
        deviceKey: SymmetricKey?,
        fileManager: FileManager = .default
    ) throws -> MacClippyBackupValidation {
        try validate(
            at: snapshotURL,
            deviceKey: deviceKey,
            fileManager: fileManager,
            shouldContinue: { true }
        )
    }

    static func validate(
        at snapshotURL: URL,
        deviceKey: SymmetricKey?,
        fileManager: FileManager = .default,
        shouldContinue: () -> Bool
    ) throws -> MacClippyBackupValidation {
        try ensureContinues(shouldContinue)
        let manifest = try readManifest(at: snapshotURL, fileManager: fileManager)
        try validateRequiredComponents(
            manifest,
            snapshotURL: snapshotURL,
            fileManager: fileManager,
            shouldContinue: shouldContinue
        )
        try validateManifestFiles(
            manifest,
            snapshotURL: snapshotURL,
            fileManager: fileManager,
            shouldContinue: shouldContinue
        )
        try validateSnapshotContents(
            snapshotURL,
            manifestPaths: Set(manifest.files.map(\.relativePath)),
            fileManager: fileManager,
            shouldContinue: shouldContinue
        )
        let keyCompatible = try authenticateKeyIfPresent(
            deviceKey,
            manifest: manifest,
            snapshotURL: snapshotURL,
            fileManager: fileManager,
            shouldContinue: shouldContinue
        )
        let (health, rowCounts) = try inspectDatabases(
            manifest,
            snapshotURL: snapshotURL,
            fileManager: fileManager,
            shouldContinue: shouldContinue
        )
        return MacClippyBackupValidation(
            manifest: manifest,
            databaseHealth: health,
            databaseRowCounts: rowCounts,
            keyCompatible: keyCompatible
        )
    }

    @discardableResult
    public static func restore(
        from snapshotURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> MacClippyBackupValidation {
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw MacClippyBackupError.destinationExists
        }
        _ = try validate(at: snapshotURL, fileManager: fileManager)
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(".macclippy-restore-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.copyItem(at: snapshotURL, to: temporaryURL)
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            do {
                try fileManager.removeItem(at: temporaryURL)
            } catch {
                MacClippyLog.record(
                    category: .storage,
                    code: .recoveryFailed,
                    operation: "restore_cleanup",
                    recoveryAction: "remove_temporary_restore",
                    impact: "temporary_restore_cleanup_failed"
                )
            }
            throw error
        }
        return try validate(at: destinationURL, fileManager: fileManager)
    }
}
