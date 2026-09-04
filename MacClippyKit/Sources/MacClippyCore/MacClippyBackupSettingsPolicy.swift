import Foundation

public struct MacClippyBackupInstallOperation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case database
        case directory
    }

    public let sourceRelativePath: String
    public let destinationRelativePath: String
    public let kind: Kind

    public init(sourceRelativePath: String, destinationRelativePath: String, kind: Kind) {
        self.sourceRelativePath = sourceRelativePath
        self.destinationRelativePath = destinationRelativePath
        self.kind = kind
    }
}

/// Settings Backup/Restore decisions for the existing portable snapshot.
/// `MacClippyBackup.create` writes databases next to `blobs/`; live storage
/// keeps those files under `databases/`. Restore copies through this map
/// instead of replacing the entire Application Support root.
public enum MacClippyBackupSettingsPolicy {
    public static let requiredDatabaseNames = ["clipboard", "pinboards", "search", "snippets"]

    public static func suggestedFolderName(
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "MacClippy-Backup-\(formatter.string(from: now))"
    }

    public static func installOperations() -> [MacClippyBackupInstallOperation] {
        requiredDatabaseNames.map { name in
            MacClippyBackupInstallOperation(
                sourceRelativePath: "\(name).sqlite",
                destinationRelativePath: "databases/\(name).sqlite",
                kind: .database
            )
        } + [
            MacClippyBackupInstallOperation(
                sourceRelativePath: "blobs",
                destinationRelativePath: "blobs",
                kind: .directory
            )
        ]
    }

    public static func sqliteSidecarRelativePaths(for destinationRelativePath: String) -> [String] {
        [destinationRelativePath + "-wal", destinationRelativePath + "-shm"]
    }

    public static func directoriesToClearOnRestore() -> [String] {
        [MacClippyThumbnailCachePolicy.directoryName]
    }

    public static func stagingURL(for destination: URL) -> URL {
        destination.appendingPathExtension("macclippy-restore-staging")
    }

    /// Copy `source` beside `destination`, then replace. The live item is not
    /// deleted until the incoming copy exists.
    public static func replaceLiveItem(
        at destination: URL,
        withContentsOf source: URL,
        fileManager: FileManager = .default
    ) throws {
        let staging = stagingURL(for: destination)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.copyItem(at: source, to: staging)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    public static func canRestore(_ validation: MacClippyBackupValidation) -> Bool {
        Set(validation.manifest.databaseNames) == Set(requiredDatabaseNames)
            && requiredDatabaseNames.allSatisfy { name in
                guard let health = validation.databaseHealth[name] else { return false }
                return health.quickCheckPassed && health.status != .unrecoverable
            }
    }

    public static func containsManifest(at snapshotURL: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(
            atPath: snapshotURL.appendingPathComponent(MacClippyBackup.manifestFileName).path
        )
    }

    public static func message(for error: MacClippyBackupError) -> String {
        switch error {
        case .destinationExists:
            return "A backup already exists at that location. Choose a new folder."
        case .invalidManifest:
            return "This folder is not a valid MacClippy backup."
        case let .missingComponent(name):
            return "This backup is incomplete (missing \(name))."
        case let .checksumMismatch(name):
            return "This backup is damaged (\(name) does not match)."
        }
    }

    public static func createSuccessMessage(databaseCount: Int) -> String {
        "Backup created with \(databaseCount) databases."
    }

    public static func restoreSuccessMessage() -> String {
        "Backup restored. History, pinboards, and snippets were replaced."
    }
}
