import CryptoKit
import Foundation
import GRDB

extension MacClippyBackup {
    static func backup(_ source: DatabaseQueue, to destinationURL: URL) throws {
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

    static func normalize(_ destinationURL: URL) throws {
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

        // SQLite may leave an empty shared-memory sidecar after switching a
        // copied WAL database back to DELETE mode. All snapshot connections
        // are closed here, so the transient file can be removed safely.
        let sharedMemoryURL = URL(fileURLWithPath: destinationURL.path + "-shm")
        if FileManager.default.fileExists(atPath: sharedMemoryURL.path) {
            try FileManager.default.removeItem(at: sharedMemoryURL)
        }
    }

    static func copyBlobFiles(
        from source: URL,
        to destination: URL,
        fileManager: FileManager,
        shouldContinue: () -> Bool = { true }
    ) throws -> [MacClippyBackupManifest.FileEntry] {
        let blobDestination = destination.appendingPathComponent("blobs", isDirectory: true)
        try fileManager.createDirectory(at: blobDestination, withIntermediateDirectories: true)
        var entries: [MacClippyBackupManifest.FileEntry] = []
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw enumerationError ?? MacClippyBackupError.missingComponent("blobs/")
        }
        for case let url as URL in enumerator {
            try ensureContinues(shouldContinue)
            guard url.deletingLastPathComponent().standardizedFileURL == source.standardizedFileURL,
                  url.pathExtension == "bin" else { continue }
            let sourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
                throw MacClippyBackupError.invalidManifest
            }
            let target = blobDestination.appendingPathComponent(url.lastPathComponent)
            try copyFile(
                from: url,
                to: target,
                fileManager: fileManager,
                shouldContinue: shouldContinue
            )
            let relativePath = "blobs/\(url.lastPathComponent)"
            let values = try target.resourceValues(forKeys: [.fileSizeKey])
            entries.append(
                .init(
                    relativePath: relativePath,
                    byteCount: Int64(values.fileSize ?? 0),
                    sha256: try sha256(for: target, shouldContinue: shouldContinue)
                )
            )
        }
        if let enumerationError { throw enumerationError }
        return entries
    }

    private static func copyFile(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager,
        shouldContinue: () -> Bool
    ) throws {
        try ensureContinues(shouldContinue)
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw MacClippyBackupError.databaseCopyFailed("blob")
        }
        let source = try FileHandle(forReadingFrom: sourceURL)
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? source.close()
            try? destination.close()
        }
        while true {
            try ensureContinues(shouldContinue)
            guard let data = try source.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            try destination.write(contentsOf: data)
        }
    }

    static func fileEntries(
        in directory: URL,
        excluding: String,
        fileManager: FileManager,
        shouldContinue: () -> Bool = { true }
    ) throws -> [MacClippyBackupManifest.FileEntry] {
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        var entries: [MacClippyBackupManifest.FileEntry] = []
        for url in urls where url.lastPathComponent != excluding && url.pathExtension == "sqlite" {
            try ensureContinues(shouldContinue)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            entries.append(
                .init(
                    relativePath: url.lastPathComponent,
                    byteCount: Int64(values.fileSize ?? 0),
                    sha256: try sha256(for: url, shouldContinue: shouldContinue)
                )
            )
        }
        return entries
    }

    static func sha256(for url: URL, shouldContinue: () -> Bool = { true }) throws -> String {
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
        while true {
            try ensureContinues(shouldContinue)
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func requiredTables(for name: String) -> Set<String> {
        switch name {
        case "clipboard": return ["clipboard_records", "clipboard_representations", "grdb_migrations"]
        case "search":
            return ["macclippy_search_index", "macclippy_search_keys", "macclippy_search_state", "grdb_migrations"]
        case "pinboards": return ["macclippy_pinboards", "grdb_migrations"]
        case "snippets": return ["macclippy_snippets", "grdb_migrations"]
        default: return ["grdb_migrations"]
        }
    }

    static func rowCountSQL(for name: String) -> String {
        switch name {
        case "clipboard": return "SELECT COUNT(*) FROM clipboard_records"
        case "search": return "SELECT COUNT(*) FROM macclippy_search_keys"
        case "pinboards": return "SELECT COUNT(*) FROM macclippy_pinboards"
        case "snippets": return "SELECT COUNT(*) FROM macclippy_snippets"
        default: return "SELECT COUNT(*) FROM grdb_migrations"
        }
    }
}
