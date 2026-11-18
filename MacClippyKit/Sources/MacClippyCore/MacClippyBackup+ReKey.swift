import CryptoKit
import Foundation
import GRDB

extension MacClippyBackup {
    @discardableResult
    public static func createArchive(
        sources: [MacClippyBackupSource],
        blobsURL: URL,
        keySource: MacClippyBackupKeySource,
        to destinationURL: URL,
        options: MacClippyBackupArchiveOptions
    ) throws -> MacClippyBackupManifest {
        let snapshots = try beginReadSnapshots(sources: sources)
        return try createArchive(
            snapshots: snapshots,
            blobsURL: blobsURL,
            keySource: keySource,
            to: destinationURL,
            options: options
        )
    }

    @discardableResult
    public static func createArchive(
        snapshots: [MacClippyBackupReadSnapshot],
        blobsURL: URL,
        keySource: MacClippyBackupKeySource,
        to destinationURL: URL,
        options: MacClippyBackupArchiveOptions
    ) throws -> MacClippyBackupManifest {
        let fileManager = options.fileManager
        if !options.overwriteExisting, fileManager.fileExists(atPath: destinationURL.path) {
            throw MacClippyBackupError.destinationExists
        }
        let tempSnapshotURL = fileManager.temporaryDirectory.appendingPathComponent(
            "MacClippy-ArchiveStage-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: tempSnapshotURL) }

        let manifest = try create(
            snapshots: snapshots,
            blobsURL: blobsURL,
            keySource: keySource,
            at: tempSnapshotURL,
            now: options.now,
            shouldContinue: options.shouldContinue,
            fileManager: fileManager
        )
        try MacClippyBackupArchive.pack(
            snapshotDirectory: tempSnapshotURL,
            sourceKey: keySource.key,
            to: destinationURL,
            options: options
        )
        return manifest
    }

    public static func validateArchive(
        at archiveURL: URL,
        passphrase: String,
        fileManager: FileManager = .default
    ) throws -> MacClippyBackupValidation {
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "MacClippy-ArchiveValidate-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: tempDirectory) }
        let sourceKey = try MacClippyBackupArchive.unpack(
            archiveURL: archiveURL,
            to: tempDirectory,
            passphrase: passphrase,
            fileManager: fileManager
        )
        return try validate(at: tempDirectory, deviceKey: sourceKey, fileManager: fileManager)
    }

    @discardableResult
    public static func installArchiveIntoLiveRoot(
        from archiveURL: URL,
        passphrase: String,
        liveRootURL: URL,
        targetKeySource: MacClippyBackupKeySource,
        fileManager: FileManager = .default
    ) throws -> MacClippyBackupValidation {
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "MacClippy-ArchiveRestore-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: tempDirectory) }
        let sourceKey = try MacClippyBackupArchive.unpack(
            archiveURL: archiveURL,
            to: tempDirectory,
            passphrase: passphrase,
            fileManager: fileManager
        )
        let validation = try validate(at: tempDirectory, deviceKey: sourceKey, fileManager: fileManager)
        guard MacClippyBackupSettingsPolicy.canRestore(validation) else {
            throw MacClippyBackupError.invalidManifest
        }
        return try installValidatedSnapshot(
            from: tempDirectory,
            liveRootURL: liveRootURL,
            sourceKey: sourceKey,
            targetKey: targetKeySource.key,
            prevalidated: validation,
            fileManager: fileManager
        )
    }

    static func rekeyStagedStorage(
        at stagedURL: URL,
        from sourceKey: SymmetricKey,
        to targetKey: SymmetricKey,
        fileManager: FileManager = .default
    ) throws {
        guard !keysMatch(sourceKey, targetKey) else { return }
        let blobsURL = stagedURL.appendingPathComponent("blobs", isDirectory: true)
        try rekeyBlobs(at: blobsURL, from: sourceKey, to: targetKey, fileManager: fileManager)
        let databasesURL = stagedURL.appendingPathComponent("databases", isDirectory: true)
        try rekeySimpleEnvelopeDatabase(
            at: databasesURL.appendingPathComponent("pinboards.sqlite"),
            table: "macclippy_pinboards",
            from: sourceKey,
            to: targetKey
        )
        try rekeySimpleEnvelopeDatabase(
            at: databasesURL.appendingPathComponent("snippets.sqlite"),
            table: "macclippy_snippets",
            from: sourceKey,
            to: targetKey
        )
        try rekeyClipboardDatabase(
            at: databasesURL.appendingPathComponent("clipboard.sqlite"),
            from: sourceKey,
            to: targetKey
        )
    }

    private static func keysMatch(_ lhs: SymmetricKey, _ rhs: SymmetricKey) -> Bool {
        lhs.withUnsafeBytes { Data($0) } == rhs.withUnsafeBytes { Data($0) }
    }

    private static func rekeyBlobs(
        at blobsURL: URL,
        from sourceKey: SymmetricKey,
        to targetKey: SymmetricKey,
        fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: blobsURL.path),
              let enumerator = fileManager.enumerator(
                at: blobsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return
        }
        for case let url as URL in enumerator where url.pathExtension == "bin" {
            let resealed = try resealEnvelope(try Data(contentsOf: url), from: sourceKey, to: targetKey)
            try resealed.write(to: url, options: .atomic)
        }
    }

    private static func rekeySimpleEnvelopeDatabase(
        at url: URL,
        table: String,
        from sourceKey: SymmetricKey,
        to targetKey: SymmetricKey
    ) throws {
        let database = try MacClippyDatabase(url: url)
        do {
            try database.queue.write { connection in
                let selectSQL = "SELECT rowid, envelope FROM \(table) WHERE envelope IS NOT NULL"
                let rows = try Row.fetchAll(connection, sql: selectSQL)
                let updateSQL = "UPDATE \(table) SET envelope = ? WHERE rowid = ?"
                for row in rows {
                    guard let rowID: Int64 = row["rowid"], let combined: Data = row["envelope"] else { continue }
                    let resealed = try resealEnvelope(combined, from: sourceKey, to: targetKey)
                    try connection.execute(sql: updateSQL, arguments: [resealed, rowID])
                }
            }
            try database.queue.close()
        } catch {
            try? database.queue.close()
            throw error
        }
    }

    private static func rekeyClipboardDatabase(
        at url: URL,
        from sourceKey: SymmetricKey,
        to targetKey: SymmetricKey
    ) throws {
        let database = try MacClippyDatabase(url: url)
        do {
            try database.queue.write { connection in
                try rekeyClipboardDatabaseLocked(connection, from: sourceKey, to: targetKey)
            }
            try database.queue.close()
        } catch {
            try? database.queue.close()
            throw error
        }
    }

    private static func rekeyClipboardDatabaseLocked(
        _ connection: Database,
        from sourceKey: SymmetricKey,
        to targetKey: SymmetricKey
    ) throws {
        let repCols = try Row.fetchAll(connection, sql: "PRAGMA table_info(clipboard_representations)")
        let hasItemIndex = repCols.contains { ($0["name"] as String?) == "item_index" }
        let recCols = try Row.fetchAll(connection, sql: "PRAGMA table_info(clipboard_records)")
        let hasRosterColumn = recCols.contains { ($0["name"] as String?) == "representation_refs_auth" }

        let repRows = try Row.fetchAll(
            connection,
            sql: "SELECT rowid, payload FROM clipboard_representations WHERE payload IS NOT NULL"
        )
        for row in repRows {
            guard let rowID: Int64 = row["rowid"], let payload: Data = row["payload"] else { continue }
            let resealed = try resealEnvelope(payload, from: sourceKey, to: targetKey)
            try connection.execute(
                sql: "UPDATE clipboard_representations SET payload = ? WHERE rowid = ?",
                arguments: [resealed, rowID]
            )
        }

        let rosterSelect = hasRosterColumn ? "representation_refs_auth" : "NULL AS representation_refs_auth"
        let recordRows = try Row.fetchAll(
            connection,
            sql: "SELECT id, envelope, \(rosterSelect) FROM clipboard_records"
        )
        for row in recordRows {
            guard let recordID: String = row["id"], let envelope: Data = row["envelope"] else { continue }
            let resealedEnvelope = try resealEnvelope(envelope, from: sourceKey, to: targetKey)
            if hasRosterColumn, let oldRosterData: Data = row["representation_refs_auth"] {
                let oldRoster = try MacClippyRepresentationRosterCodec.open(oldRosterData, key: sourceKey)
                let maxReps = MacClippyPasteboardInputLimits.default.maxRepresentationsPerRecord
                let updatedRoster = try MacClippyRepresentationRosterCodec.current(
                    recordID: recordID,
                    on: connection,
                    maxRepresentations: maxReps,
                    version: oldRoster.version,
                    hasItemIndexColumn: hasItemIndex
                )
                let newRosterData = try MacClippyRepresentationRosterCodec.seal(updatedRoster, key: targetKey)
                try connection.execute(
                    sql: "UPDATE clipboard_records SET envelope = ?, representation_refs_auth = ? WHERE id = ?",
                    arguments: [resealedEnvelope, newRosterData, recordID]
                )
            } else {
                try connection.execute(
                    sql: "UPDATE clipboard_records SET envelope = ? WHERE id = ?",
                    arguments: [resealedEnvelope, recordID]
                )
            }
        }
    }

    private static func resealEnvelope(
        _ combined: Data,
        from sourceKey: SymmetricKey,
        to targetKey: SymmetricKey
    ) throws -> Data {
        let plaintext = try MacClippyCipher.open(MacClippyEnvelope(combined: combined), with: sourceKey)
        return try MacClippyCipher.seal(plaintext, with: targetKey).combined
    }
}
