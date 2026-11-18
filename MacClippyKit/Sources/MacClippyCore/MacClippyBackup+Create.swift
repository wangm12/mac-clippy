import Foundation

private struct MacClippyBackupCreationSettings {
    let keySource: MacClippyBackupKeySource
    let now: Date
    let fileManager: FileManager
    let shouldContinue: () -> Bool
}

extension MacClippyBackup {
    @discardableResult
    public static func create(
        snapshots: [MacClippyBackupReadSnapshot],
        blobsURL: URL,
        keySource: MacClippyBackupKeySource,
        at destinationURL: URL,
        now: Date = Date(),
        shouldContinue: @escaping () -> Bool = { true },
        fileManager: FileManager = .default
    ) throws -> MacClippyBackupManifest {
        let settings = MacClippyBackupCreationSettings(
            keySource: keySource,
            now: now,
            fileManager: fileManager,
            shouldContinue: shouldContinue
        )
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw MacClippyBackupError.destinationExists
        }
        try validateNames(snapshots.map(\.name))
        try ensureContinues(shouldContinue)
        let parent = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(
            ".macclippy-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryURL, withIntermediateDirectories: true)

        do {
            try copySnapshots(snapshots, to: temporaryURL, shouldContinue: shouldContinue)
            let copiedBlobFiles = try copyBlobFiles(
                from: blobsURL,
                to: temporaryURL,
                fileManager: fileManager,
                shouldContinue: shouldContinue
            )
            let manifest = try makeManifest(
                snapshots: snapshots,
                blobFiles: copiedBlobFiles,
                directory: temporaryURL,
                settings: settings
            )
            try publish(
                manifest,
                from: temporaryURL,
                to: destinationURL,
                settings: settings
            )
            return manifest
        } catch {
            cleanTemporaryBackup(temporaryURL, fileManager: fileManager)
            throw error
        }
    }

    private static func copySnapshots(
        _ snapshots: [MacClippyBackupReadSnapshot],
        to directory: URL,
        shouldContinue: () -> Bool
    ) throws {
        for snapshot in snapshots {
            try ensureContinues(shouldContinue)
            let target = directory.appendingPathComponent(snapshot.name + ".sqlite")
            try snapshot.copy(to: target, shouldContinue: shouldContinue)
        }
    }

    private static func makeManifest(
        snapshots: [MacClippyBackupReadSnapshot],
        blobFiles: [MacClippyBackupManifest.FileEntry],
        directory: URL,
        settings: MacClippyBackupCreationSettings
    ) throws -> MacClippyBackupManifest {
        let databaseNames = snapshots.map(\.name).sorted()
        let files = try fileEntries(
            in: directory,
            excluding: manifestFileName,
            fileManager: settings.fileManager,
            shouldContinue: settings.shouldContinue
        )
        return MacClippyBackupManifest(
            formatVersion: currentFormatVersion,
            createdAt: settings.now,
            databaseNames: databaseNames,
            files: files + blobFiles,
            keyCheck: try MacClippyCipher.seal(keyCheckSentinel, with: settings.keySource.key)
                .combined.base64EncodedString()
        )
    }

    private static func publish(
        _ manifest: MacClippyBackupManifest,
        from temporaryURL: URL,
        to destinationURL: URL,
        settings: MacClippyBackupCreationSettings
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: temporaryURL.appendingPathComponent(manifestFileName),
            options: .atomic
        )
        _ = try validate(
            at: temporaryURL,
            deviceKey: settings.keySource.key,
            fileManager: settings.fileManager,
            shouldContinue: settings.shouldContinue
        )
        try ensureContinues(settings.shouldContinue)
        try settings.fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private static func cleanTemporaryBackup(_ url: URL, fileManager: FileManager) {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            MacClippyLog.record(
                category: .storage,
                code: .backupFailed,
                operation: "backup_cleanup",
                recoveryAction: "remove_temporary_backup",
                impact: "temporary_backup_cleanup_failed"
            )
        }
    }
}
