import CryptoKit
import Foundation

extension MacClippyBackup {
    private struct RestorePreparation {
        let snapshotURL: URL
        let transactionURL: URL
        let stagedURL: URL
        let previousURL: URL
        let liveRootURL: URL
        let key: SymmetricKey
    }

    /// Copies a validated snapshot into an existing live Application Support
    /// root. Callers must close live database queues first and only finalize
    /// after the new runtime opens successfully.
    @discardableResult
    public static func installIntoLiveRoot(
        from snapshotURL: URL,
        liveRootURL: URL,
        keySource: MacClippyBackupKeySource,
        fileManager: FileManager = .default
    ) throws -> MacClippyBackupValidation {
        try installIntoLiveRoot(
            from: snapshotURL,
            liveRootURL: liveRootURL,
            deviceKey: keySource.key,
            fileManager: fileManager,
            faultInjector: nil
        )
    }

    @discardableResult
    static func installIntoLiveRoot(
        from snapshotURL: URL,
        liveRootURL: URL,
        deviceKey: SymmetricKey,
        fileManager: FileManager = .default
    ) throws -> MacClippyBackupValidation {
        try installIntoLiveRoot(
            from: snapshotURL,
            liveRootURL: liveRootURL,
            deviceKey: deviceKey,
            fileManager: fileManager,
            faultInjector: nil
        )
    }

    @discardableResult
    static func installIntoLiveRoot(
        from snapshotURL: URL,
        liveRootURL: URL,
        deviceKey: SymmetricKey?,
        fileManager: FileManager = .default,
        faultInjector: ((RestoreFaultPoint) throws -> Void)?
    ) throws -> MacClippyBackupValidation {
        guard let deviceKey else { throw MacClippyBackupError.keyRequired }
        let validation = try validate(at: snapshotURL, deviceKey: deviceKey, fileManager: fileManager)
        guard MacClippyBackupSettingsPolicy.canRestore(validation) else {
            throw MacClippyBackupError.invalidManifest
        }
        try fileManager.createDirectory(at: liveRootURL, withIntermediateDirectories: true)
        try recoverPendingRestore(at: liveRootURL, fileManager: fileManager)

        let transactionURL = liveRootURL.appendingPathComponent(
            ".macclippy-restore-\(UUID().uuidString)",
            isDirectory: true
        )
        let stagedURL = transactionURL.appendingPathComponent("staged", isDirectory: true)
        let previousURL = transactionURL.appendingPathComponent("previous", isDirectory: true)
        do {
            let preparation = RestorePreparation(
                snapshotURL: snapshotURL,
                transactionURL: transactionURL,
                stagedURL: stagedURL,
                previousURL: previousURL,
                liveRootURL: liveRootURL,
                key: deviceKey
            )
            try prepareRestoreTransaction(
                preparation,
                fileManager: fileManager
            )
            try installStagedComponents(
                stagedURL: stagedURL,
                liveRootURL: liveRootURL,
                fileManager: fileManager,
                faultInjector: faultInjector
            )
        } catch MacClippyBackupError.restoreInterrupted {
            throw MacClippyBackupError.restoreInterrupted
        } catch {
            try rollbackOrRemovePartialRestore(
                transactionURL: transactionURL,
                liveRootURL: liveRootURL,
                fileManager: fileManager
            )
            throw error
        }
        return validation
    }

    private static func prepareRestoreTransaction(
        _ preparation: RestorePreparation,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: preparation.stagedURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: preparation.previousURL, withIntermediateDirectories: true)
        try stageSnapshot(preparation.snapshotURL, into: preparation.stagedURL, fileManager: fileManager)
        let databasesURL = preparation.stagedURL.appendingPathComponent("databases", isDirectory: true)
        try openStagedStorage(at: databasesURL, key: preparation.key)

        var hadOriginal: [String: Bool] = [:]
        for component in liveComponents {
            let current = preparation.liveRootURL.appendingPathComponent(component, isDirectory: true)
            let previous = preparation.previousURL.appendingPathComponent(component, isDirectory: true)
            let existed = fileManager.fileExists(atPath: current.path)
            hadOriginal[component] = existed
            if existed { try fileManager.copyItem(at: current, to: previous) }
        }

        let journal = RestoreJournal(
            transactionDirectory: preparation.transactionURL.lastPathComponent,
            hadOriginalComponent: hadOriginal,
            finalized: false
        )
        try writeRestoreJournal(journal, at: preparation.liveRootURL, fileManager: fileManager)
    }

    private static func installStagedComponents(
        stagedURL: URL,
        liveRootURL: URL,
        fileManager: FileManager,
        faultInjector: ((RestoreFaultPoint) throws -> Void)?
    ) throws {
        do {
            for component in liveComponents {
                try faultInjector?(.beforeInstall(component))
                let destination = liveRootURL.appendingPathComponent(component, isDirectory: true)
                let incoming = stagedURL.appendingPathComponent(component, isDirectory: true)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: incoming, to: destination)
                try faultInjector?(.afterInstall(component))
            }
            try faultInjector?(.beforeCommit)
        } catch MacClippyBackupError.restoreInterrupted {
            // Leave the journal and backups intact to simulate process death.
            throw MacClippyBackupError.restoreInterrupted
        } catch {
            try recoverPendingRestore(at: liveRootURL, fileManager: fileManager)
            throw error
        }
    }

    private static func rollbackOrRemovePartialRestore(
        transactionURL: URL,
        liveRootURL: URL,
        fileManager: FileManager
    ) throws {
        let journalURL = liveRootURL.appendingPathComponent(restoreJournalFileName)
        if fileManager.fileExists(atPath: journalURL.path) {
            try recoverPendingRestore(at: liveRootURL, fileManager: fileManager)
        } else if fileManager.fileExists(atPath: transactionURL.path) {
            try fileManager.removeItem(at: transactionURL)
        }
    }

    /// Recovers an interrupted install. Uncommitted transactions restore every
    /// original component from the durable previous-copy set. A finalized
    /// transaction keeps the root selected before the marker was written and
    /// only removes journal artifacts. Re-running recovery is safe.
    public static func recoverPendingRestore(
        at liveRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try recoverPendingRestore(at: liveRootURL, fileManager: fileManager, faultInjector: nil)
    }

    static func recoverPendingRestore(
        at liveRootURL: URL,
        fileManager: FileManager = .default,
        faultInjector: ((RestoreFaultPoint) throws -> Void)?
    ) throws {
        let journalURL = liveRootURL.appendingPathComponent(restoreJournalFileName)
        guard fileManager.fileExists(atPath: journalURL.path) else { return }
        let data = try Data(contentsOf: journalURL)
        var journal = try JSONDecoder().decode(RestoreJournal.self, from: data)
        guard journal.transactionDirectory.hasPrefix(".macclippy-restore-"),
              !journal.transactionDirectory.contains("/") else {
            throw MacClippyBackupError.invalidManifest
        }
        let transactionURL = liveRootURL.appendingPathComponent(journal.transactionDirectory, isDirectory: true)
        if !journal.finalized {
            let previousURL = transactionURL.appendingPathComponent("previous", isDirectory: true)
            for component in liveComponents {
                let destination = liveRootURL.appendingPathComponent(component, isDirectory: true)
                if journal.hadOriginalComponent[component] == true {
                    let backup = previousURL.appendingPathComponent(component, isDirectory: true)
                    guard fileManager.fileExists(atPath: backup.path) else {
                        throw MacClippyBackupError.missingComponent("restore backup: \(component)")
                    }
                    let replacement = transactionURL.appendingPathComponent("rollback-\(component)", isDirectory: true)
                    if fileManager.fileExists(atPath: replacement.path) { try fileManager.removeItem(at: replacement) }
                    try fileManager.copyItem(at: backup, to: replacement)
                    if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                    try fileManager.moveItem(at: replacement, to: destination)
                    try faultInjector?(.afterRollback(component))
                } else if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                    try faultInjector?(.afterRollback(component))
                }
            }
            // Persist that the old root is now the selected whole-store state
            // before deleting its recovery copy. If recovery itself is
            // interrupted during cleanup, another startup only needs to keep
            // the already-restored root and finish removing transaction files.
            journal.finalized = true
            try writeRestoreJournal(journal, at: liveRootURL, fileManager: fileManager)
            try faultInjector?(.afterRollbackCommit)
        }
        try faultInjector?(.beforeTransactionCleanup)
        if fileManager.fileExists(atPath: transactionURL.path) { try fileManager.removeItem(at: transactionURL) }
        try faultInjector?(.afterTransactionCleanup)
        try faultInjector?(.beforeJournalCleanup)
        try removeRestoreJournal(at: liveRootURL, fileManager: fileManager)
    }

    /// Commits an installed restore after the application has opened the new
    /// runtime successfully. Until this point, startup recovery rolls back to
    /// the original complete store.
    public static func finalizePendingRestore(
        at liveRootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let journalURL = liveRootURL.appendingPathComponent(restoreJournalFileName)
        guard fileManager.fileExists(atPath: journalURL.path) else { return }
        let data = try Data(contentsOf: journalURL)
        var journal = try JSONDecoder().decode(RestoreJournal.self, from: data)
        guard journal.transactionDirectory.hasPrefix(".macclippy-restore-"),
              !journal.transactionDirectory.contains("/") else {
            throw MacClippyBackupError.invalidManifest
        }
        journal.finalized = true
        try writeRestoreJournal(journal, at: liveRootURL, fileManager: fileManager)
        let transactionURL = liveRootURL.appendingPathComponent(journal.transactionDirectory, isDirectory: true)
        if fileManager.fileExists(atPath: transactionURL.path) { try fileManager.removeItem(at: transactionURL) }
        try removeRestoreJournal(at: liveRootURL, fileManager: fileManager)
    }

    static func stageSnapshot(
        _ snapshotURL: URL,
        into stagingRootURL: URL,
        fileManager: FileManager
    ) throws {
        let databasesURL = stagingRootURL.appendingPathComponent("databases", isDirectory: true)
        try fileManager.createDirectory(at: databasesURL, withIntermediateDirectories: true)
        for name in MacClippyBackupSettingsPolicy.requiredDatabaseNames {
            try fileManager.copyItem(
                at: snapshotURL.appendingPathComponent("\(name).sqlite"),
                to: databasesURL.appendingPathComponent("\(name).sqlite")
            )
        }
        try fileManager.copyItem(
            at: snapshotURL.appendingPathComponent("blobs", isDirectory: true),
            to: stagingRootURL.appendingPathComponent("blobs", isDirectory: true)
        )
        try fileManager.createDirectory(
            at: stagingRootURL.appendingPathComponent(MacClippyThumbnailCachePolicy.directoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    static func openStagedStorage(at databasesURL: URL, key: SymmetricKey) throws {
        let clipboardDatabase = try MacClippyDatabase(url: databasesURL.appendingPathComponent("clipboard.sqlite"))
        let searchDatabase = try MacClippyDatabase(url: databasesURL.appendingPathComponent("search.sqlite"))
        let pinboardsDatabase = try MacClippyDatabase(url: databasesURL.appendingPathComponent("pinboards.sqlite"))
        let snippetsDatabase = try MacClippyDatabase(url: databasesURL.appendingPathComponent("snippets.sqlite"))
        defer {
            [clipboardDatabase, searchDatabase, pinboardsDatabase, snippetsDatabase].forEach { database in
                try? database.queue.close()
            }
        }

        _ = try ClipboardStore(database: clipboardDatabase, deviceKey: key)
        _ = try SearchStore(database: searchDatabase)
        _ = try PinboardStore(database: pinboardsDatabase, deviceKey: key).listStrict()
        _ = try SnippetStore(database: snippetsDatabase, deviceKey: key).listStrict()
    }

    static func writeRestoreJournal(
        _ journal: RestoreJournal,
        at rootURL: URL,
        fileManager: FileManager
    ) throws {
        let url = rootURL.appendingPathComponent(restoreJournalFileName)
        let data = try JSONEncoder().encode(journal)
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }

    static func removeRestoreJournal(at rootURL: URL, fileManager: FileManager) throws {
        let url = rootURL.appendingPathComponent(restoreJournalFileName)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }
}
