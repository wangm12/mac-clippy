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

    public init(formatVersion: Int, createdAt: Date, databaseNames: [String], files: [FileEntry]) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.databaseNames = databaseNames
        self.files = files
    }
}

public struct MacClippyBackupValidation: Sendable, Equatable {
    public let manifest: MacClippyBackupManifest
    public let databaseHealth: [String: MacClippyDatabaseHealthReport]
    public let databaseRowCounts: [String: Int64]

    public init(
        manifest: MacClippyBackupManifest,
        databaseHealth: [String: MacClippyDatabaseHealthReport],
        databaseRowCounts: [String: Int64]
    ) {
        self.manifest = manifest
        self.databaseHealth = databaseHealth
        self.databaseRowCounts = databaseRowCounts
    }
}

public enum MacClippyBackupError: Error, Equatable {
    case destinationExists
    case invalidManifest
    case missingComponent(String)
    case checksumMismatch(String)
}

/// Creates and validates a portable local snapshot. Database files are copied
/// through SQLite's online backup API, not with FileManager, so WAL contents
/// are included consistently. Callers must serialize this operation with
/// application writes (the runtime's store lock is the intended boundary).
public enum MacClippyBackup {
    public static let manifestFileName = "manifest.json"
    private static let formatVersion = 1

    @discardableResult
    public static func create(
        sources: [MacClippyBackupSource],
        blobsURL: URL,
        at destinationURL: URL,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> MacClippyBackupManifest {
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw MacClippyBackupError.destinationExists
        }
        try validateNames(sources.map(\.name))
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(".macclippy-backup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)

        do {
            for source in sources {
                let destinationDatabaseURL = temporaryURL.appendingPathComponent(source.name + ".sqlite")
                try backup(source.database.queue, to: destinationDatabaseURL)
            }

            let copiedBlobFiles = try copyBlobFiles(from: blobsURL, to: temporaryURL, fileManager: fileManager)
            let databaseNames = sources.map(\.name).sorted()
            let files = try fileEntries(in: temporaryURL, excluding: manifestFileName, fileManager: fileManager)
            let manifest = MacClippyBackupManifest(
                formatVersion: formatVersion,
                createdAt: now,
                databaseNames: databaseNames,
                files: files + copiedBlobFiles
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: temporaryURL.appendingPathComponent(manifestFileName), options: .atomic)
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            return manifest
        } catch {
            do {
                try fileManager.removeItem(at: temporaryURL)
            } catch {
                MacClippyLog.record(
                    category: .storage,
                    code: .backupFailed,
                    operation: "backup_cleanup",
                    recoveryAction: "remove_temporary_backup",
                    impact: "temporary_backup_cleanup_failed"
                )
            }
            throw error
        }
    }

    public static func validate(
        at snapshotURL: URL,
        fileManager: FileManager = .default
    ) throws -> MacClippyBackupValidation {
        let manifestURL = snapshotURL.appendingPathComponent(manifestFileName)
        guard let manifestData = fileManager.contents(atPath: manifestURL.path) else {
            throw MacClippyBackupError.missingComponent(manifestFileName)
        }
        let manifest: MacClippyBackupManifest
        do {
            manifest = try JSONDecoder().decode(MacClippyBackupManifest.self, from: manifestData)
        } catch {
            throw MacClippyBackupError.invalidManifest
        }
        guard manifest.formatVersion == formatVersion else { throw MacClippyBackupError.invalidManifest }
        try validateNames(manifest.databaseNames)

        for file in manifest.files {
            let url = try validatedSnapshotURL(file.relativePath, root: snapshotURL)
            guard fileManager.fileExists(atPath: url.path) else {
                throw MacClippyBackupError.missingComponent(file.relativePath)
            }
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let actualByteCount = Int64(values.fileSize ?? 0)
            // SQLite may finalize a WAL/header transition when the validation
            // connection closes. Validate database logical integrity below and
            // use exact byte/hash checks for immutable blob files; raw SQLite
            // bytes are not a stable checksum boundary across that transition.
            if url.pathExtension == "sqlite" {
                guard actualByteCount == file.byteCount else {
                    throw MacClippyBackupError.checksumMismatch(file.relativePath)
                }
                continue
            }
            guard actualByteCount == file.byteCount, try sha256(for: url) == file.sha256 else {
                throw MacClippyBackupError.checksumMismatch(file.relativePath)
            }
        }

        var health: [String: MacClippyDatabaseHealthReport] = [:]
        var counts: [String: Int64] = [:]
        for name in manifest.databaseNames {
            let databaseURL = try validatedSnapshotURL(name + ".sqlite", root: snapshotURL)
            guard fileManager.fileExists(atPath: databaseURL.path) else {
                throw MacClippyBackupError.missingComponent(name + ".sqlite")
            }
            let database = try MacClippyDatabase(url: databaseURL)
            let requiredTables = requiredTables(for: name)
            health[name] = database.healthCheck(requiredTables: requiredTables, mode: .full)
            counts[name] = try database.queue.read { connection in
                try Int64.fetchOne(connection, sql: rowCountSQL(for: name)) ?? 0
            }
        }
        return MacClippyBackupValidation(manifest: manifest, databaseHealth: health, databaseRowCounts: counts)
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

    /// Copies a validated snapshot into an existing live Application Support
    /// root. Callers must close live database queues first. Databases move
    /// from the snapshot root into `databases/`; `blobs/` is replaced; stale
    /// thumbnails are cleared.
    @discardableResult
    public static func installIntoLiveRoot(
        from snapshotURL: URL,
        liveRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> MacClippyBackupValidation {
        let validation = try validate(at: snapshotURL, fileManager: fileManager)
        guard MacClippyBackupSettingsPolicy.canRestore(validation) else {
            throw MacClippyBackupError.invalidManifest
        }
        try fileManager.createDirectory(at: liveRootURL, withIntermediateDirectories: true)
        for operation in MacClippyBackupSettingsPolicy.installOperations() {
            let source = try validatedSnapshotURL(operation.sourceRelativePath, root: snapshotURL)
            let destination = liveRootURL.appendingPathComponent(operation.destinationRelativePath)
            switch operation.kind {
            case .database:
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try MacClippyBackupSettingsPolicy.replaceLiveItem(
                    at: destination,
                    withContentsOf: source,
                    fileManager: fileManager
                )
                for sidecar in MacClippyBackupSettingsPolicy.sqliteSidecarRelativePaths(
                    for: operation.destinationRelativePath
                ) {
                    let sidecarURL = liveRootURL.appendingPathComponent(sidecar)
                    if fileManager.fileExists(atPath: sidecarURL.path) {
                        try fileManager.removeItem(at: sidecarURL)
                    }
                }
            case .directory:
                try MacClippyBackupSettingsPolicy.replaceLiveItem(
                    at: destination,
                    withContentsOf: source,
                    fileManager: fileManager
                )
            }
        }
        for relative in MacClippyBackupSettingsPolicy.directoriesToClearOnRestore() {
            let url = liveRootURL.appendingPathComponent(relative, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return validation
    }

    private static func validateNames(_ names: [String]) throws {
        guard !names.isEmpty,
              Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } }) else {
            throw MacClippyBackupError.invalidManifest
        }
    }

    private static func validatedSnapshotURL(_ relativePath: String, root: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty && component != "." && component != ".."
                      && component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
              }) else {
            throw MacClippyBackupError.invalidManifest
        }

        let rootURL = root.standardizedFileURL
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard isInside(candidate, root: rootURL) else { throw MacClippyBackupError.invalidManifest }

        // A manifest must not be able to follow a symlink out of the snapshot.
        // Resolve only after the lexical check so a missing component remains a
        // normal `missingComponent` error rather than changing path semantics.
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(resolved, root: rootURL) else { throw MacClippyBackupError.invalidManifest }
        return candidate
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private static func backup(_ source: DatabaseQueue, to destinationURL: URL) throws {
        // Keep the destination queue in a small helper scope. In particular,
        // this closes the last writer before the snapshot is hashed and avoids
        // a late journal/header update after the manifest is created.
        do {
            var configuration = Configuration()
            configuration.prepareDatabase { connection in
                try connection.execute(sql: "PRAGMA journal_mode = DELETE")
                try connection.execute(sql: "PRAGMA synchronous = FULL")
            }
            let destination = try DatabaseQueue(path: destinationURL.path, configuration: configuration)
            try source.backup(to: destination)
            try destination.close()
        }
        try normalize(destinationURL)
    }

    private static func normalize(_ destinationURL: URL) throws {
        // A source opened in WAL mode can leave the destination with a WAL
        // sidecar even when the destination configuration starts in DELETE
        // mode. Reopen after the backup queue has closed, checkpoint it, and
        // switch the portable snapshot to a single main database file. The
        // dedicated helper scope closes the queue before file hashing begins.
        let checkpoint = try DatabaseQueue(path: destinationURL.path)
        try checkpoint.writeWithoutTransaction { connection in
            try connection.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try connection.execute(sql: "PRAGMA journal_mode = DELETE")
            try connection.execute(sql: "PRAGMA synchronous = FULL")
        }
        try checkpoint.close()
    }

    private static func copyBlobFiles(from source: URL, to destination: URL, fileManager: FileManager) throws -> [MacClippyBackupManifest.FileEntry] {
        let blobDestination = destination.appendingPathComponent("blobs", isDirectory: true)
        try fileManager.createDirectory(at: blobDestination, withIntermediateDirectories: true)
        let urls = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.fileSizeKey])
        var entries: [MacClippyBackupManifest.FileEntry] = []
        for url in urls where url.pathExtension == "bin" {
            let target = blobDestination.appendingPathComponent(url.lastPathComponent)
            try fileManager.copyItem(at: url, to: target)
            let relativePath = "blobs/\(url.lastPathComponent)"
            let values = try target.resourceValues(forKeys: [.fileSizeKey])
            entries.append(.init(relativePath: relativePath, byteCount: Int64(values.fileSize ?? 0), sha256: try sha256(for: target)))
        }
        return entries
    }

    private static func fileEntries(in directory: URL, excluding: String, fileManager: FileManager) throws -> [MacClippyBackupManifest.FileEntry] {
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        var entries: [MacClippyBackupManifest.FileEntry] = []
        for url in urls where url.lastPathComponent != excluding && url.pathExtension == "sqlite" {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            entries.append(.init(relativePath: url.lastPathComponent, byteCount: Int64(values.fileSize ?? 0), sha256: try sha256(for: url)))
        }
        return entries
    }

    private static func sha256(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            do {
                try handle.close()
            } catch {
                MacClippyLog.record(
                    category: .storage,
                    code: .backupFailed,
                    operation: "backup_file_close",
                    recoveryAction: "retry_backup",
                    impact: "backup_file_close_failed"
                )
            }
        }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func requiredTables(for name: String) -> Set<String> {
        switch name {
        case "clipboard": return ["clipboard_records", "clipboard_representations", "grdb_migrations"]
        case "search": return ["macclippy_search_index", "macclippy_search_keys", "macclippy_search_state", "grdb_migrations"]
        case "pinboards": return ["macclippy_pinboards", "grdb_migrations"]
        case "snippets": return ["macclippy_snippets", "grdb_migrations"]
        default: return ["grdb_migrations"]
        }
    }

    private static func rowCountSQL(for name: String) -> String {
        switch name {
        case "clipboard": return "SELECT COUNT(*) FROM clipboard_records"
        case "search": return "SELECT COUNT(*) FROM macclippy_search_keys"
        case "pinboards": return "SELECT COUNT(*) FROM macclippy_pinboards"
        case "snippets": return "SELECT COUNT(*) FROM macclippy_snippets"
        default: return "SELECT COUNT(*) FROM grdb_migrations"
        }
    }
}
