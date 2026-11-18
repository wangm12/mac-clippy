import Foundation
import GRDB

extension MacClippyBackup {
    static func readManifest(at snapshotURL: URL, fileManager: FileManager) throws -> MacClippyBackupManifest {
        let url = snapshotURL.appendingPathComponent(manifestFileName)
        guard let data = fileManager.contents(atPath: url.path) else {
            throw MacClippyBackupError.missingComponent(manifestFileName)
        }
        let manifest: MacClippyBackupManifest
        do {
            manifest = try JSONDecoder().decode(MacClippyBackupManifest.self, from: data)
        } catch {
            throw MacClippyBackupError.invalidManifest
        }
        guard manifest.formatVersion == legacyFormatVersion || manifest.formatVersion == currentFormatVersion else {
            throw MacClippyBackupError.invalidManifest
        }
        return manifest
    }

    static func validateRequiredComponents(
        _ manifest: MacClippyBackupManifest,
        snapshotURL: URL,
        fileManager: FileManager,
        shouldContinue: () -> Bool = { true }
    ) throws {
        try ensureContinues(shouldContinue)
        try validateNames(manifest.databaseNames)
        let expectedNames = MacClippyBackupSettingsPolicy.requiredDatabaseNames
        guard Set(manifest.databaseNames) == Set(expectedNames) else {
            throw MacClippyBackupError.invalidManifest
        }

        let blobsURL = try validatedSnapshotURL("blobs", root: snapshotURL)
        guard fileManager.fileExists(atPath: blobsURL.path) else {
            throw MacClippyBackupError.missingComponent("blobs/")
        }
        let values = try blobsURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw MacClippyBackupError.missingComponent("blobs/") }
    }

    static func validateManifestFiles(
        _ manifest: MacClippyBackupManifest,
        snapshotURL: URL,
        fileManager: FileManager,
        shouldContinue: () -> Bool = { true }
    ) throws {
        let paths = manifest.files.map(\.relativePath)
        guard Set(paths).count == paths.count else { throw MacClippyBackupError.invalidManifest }
        let expectedDatabases = Set(
            MacClippyBackupSettingsPolicy.requiredDatabaseNames.map { "\($0).sqlite" }
        )
        guard Set(paths.filter { $0.hasSuffix(".sqlite") }) == expectedDatabases else {
            throw MacClippyBackupError.invalidManifest
        }

        for entry in manifest.files {
            try ensureContinues(shouldContinue)
            try validateManifestFile(
                entry,
                snapshotURL: snapshotURL,
                fileManager: fileManager,
                shouldContinue: shouldContinue
            )
        }
    }

    private static func validateManifestFile(
        _ entry: MacClippyBackupManifest.FileEntry,
        snapshotURL: URL,
        fileManager: FileManager,
        shouldContinue: () -> Bool
    ) throws {
        let url = try validatedSnapshotURL(entry.relativePath, root: snapshotURL)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard fileManager.fileExists(atPath: url.path), values?.isRegularFile == true else {
            throw MacClippyBackupError.missingComponent(entry.relativePath)
        }
        let actualSize = Int64(values?.fileSize ?? 0)
        guard actualSize == entry.byteCount,
              try sha256(for: url, shouldContinue: shouldContinue) == entry.sha256 else {
            throw MacClippyBackupError.checksumMismatch(entry.relativePath)
        }
    }

    static func inspectDatabases(
        _ manifest: MacClippyBackupManifest,
        snapshotURL: URL,
        fileManager: FileManager,
        shouldContinue: () -> Bool = { true }
    ) throws -> ([String: MacClippyDatabaseHealthReport], [String: Int64]) {
        var health: [String: MacClippyDatabaseHealthReport] = [:]
        var rowCounts: [String: Int64] = [:]
        for name in manifest.databaseNames {
            try ensureContinues(shouldContinue)
            let url = try validatedSnapshotURL(name + ".sqlite", root: snapshotURL)
            try rejectSQLiteSidecars(url, fileManager: fileManager)
            let database = try MacClippyDatabase(url: url, readOnly: true)
            health[name] = database.healthCheck(
                requiredTables: requiredTables(for: name),
                mode: .full,
                shouldContinue: shouldContinue
            )
            try ensureContinues(shouldContinue)
            rowCounts[name] = try database.queue.read { connection in
                try Int64.fetchOne(connection, sql: rowCountSQL(for: name)) ?? 0
            }
            try database.queue.close()
        }
        return (health, rowCounts)
    }

    private static func rejectSQLiteSidecars(_ databaseURL: URL, fileManager: FileManager) throws {
        let sidecars = ["-wal", "-shm", "-journal"]
        guard !sidecars.contains(where: { fileManager.fileExists(atPath: databaseURL.path + $0) }) else {
            throw MacClippyBackupError.invalidManifest
        }
    }

    static func validateNames(_ names: [String]) throws {
        let isSafeName: (String) -> Bool = { name in
            !name.isEmpty && name.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
            }
        }
        guard !names.isEmpty, Set(names).count == names.count, names.allSatisfy(isSafeName) else {
            throw MacClippyBackupError.invalidManifest
        }
    }

    static func validateSnapshotContents(
        _ snapshotURL: URL,
        manifestPaths: Set<String>,
        fileManager: FileManager,
        shouldContinue: () -> Bool = { true }
    ) throws {
        try ensureContinues(shouldContinue)
        let topLevel = try fileManager.contentsOfDirectory(
            at: snapshotURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let expectedTopLevel = Set(
            [manifestFileName, "blobs"] + MacClippyBackupSettingsPolicy.requiredDatabaseNames.map { "\($0).sqlite" }
        )
        guard Set(topLevel.map(\.lastPathComponent)) == expectedTopLevel else {
            throw MacClippyBackupError.invalidManifest
        }
        let blobsURL = snapshotURL.appendingPathComponent("blobs", isDirectory: true)
        let actualBlobPaths = try blobPaths(
            in: blobsURL,
            fileManager: fileManager,
            shouldContinue: shouldContinue
        )
        let manifestBlobPaths = Set(manifestPaths.filter { $0.hasPrefix("blobs/") })
        guard actualBlobPaths == manifestBlobPaths else { throw MacClippyBackupError.invalidManifest }
    }

    private static func blobPaths(
        in directory: URL,
        fileManager: FileManager,
        shouldContinue: () -> Bool
    ) throws -> Set<String> {
        var paths = Set<String>()
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
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
            guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
                throw MacClippyBackupError.invalidManifest
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            let identifier = url.deletingPathExtension().lastPathComponent
            guard values.isRegularFile == true, url.pathExtension == "bin", isSafeBlobIdentifier(identifier) else {
                throw MacClippyBackupError.invalidManifest
            }
            paths.insert("blobs/\(url.lastPathComponent)")
        }
        if let enumerationError { throw enumerationError }
        return paths
    }

    static func isSafeBlobIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".."
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func validatedSnapshotURL(_ relativePath: String, root: URL) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"), !relativePath.hasSuffix("/"), !components.isEmpty else {
            throw MacClippyBackupError.invalidManifest
        }
        guard components.allSatisfy(isSafePathComponent) else {
            throw MacClippyBackupError.invalidManifest
        }

        let rootURL = root.standardizedFileURL
        let candidate = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard isInside(candidate, root: rootURL) else { throw MacClippyBackupError.invalidManifest }
        let values = try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { throw MacClippyBackupError.invalidManifest }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(resolved, root: rootURL) else { throw MacClippyBackupError.invalidManifest }
        return candidate
    }

    private static func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && component.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".")
            }
    }

    static func isInside(_ candidate: URL, root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }
}
