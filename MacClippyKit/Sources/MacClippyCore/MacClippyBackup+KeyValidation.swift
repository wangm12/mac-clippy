import CryptoKit
import Foundation
import GRDB

extension MacClippyBackup {
    static func authenticateKeyIfPresent(
        _ key: SymmetricKey?,
        manifest: MacClippyBackupManifest,
        snapshotURL: URL,
        fileManager: FileManager,
        shouldContinue: () -> Bool = { true }
    ) throws -> Bool {
        guard let key else { return false }
        try authenticateKey(
            key,
            manifest: manifest,
            snapshotURL: snapshotURL,
            fileManager: fileManager,
            shouldContinue: shouldContinue
        )
        try validateClipboardBlobReferences(
            key,
            manifest: manifest,
            snapshotURL: snapshotURL,
            shouldContinue: shouldContinue
        )
        return true
    }

    static func authenticateKey(
        _ key: SymmetricKey,
        manifest: MacClippyBackupManifest,
        snapshotURL: URL,
        fileManager: FileManager,
        shouldContinue: () -> Bool = { true }
    ) throws {
        if manifest.formatVersion == currentFormatVersion {
            try authenticateKeyCheck(manifest, key: key)
        }
        let databasePayloadCount = try authenticateDatabasePayloads(
            key,
            snapshotURL: snapshotURL,
            shouldContinue: shouldContinue
        )
        let blobPayloadCount = try authenticateBlobPayloads(
            key,
            snapshotURL: snapshotURL,
            fileManager: fileManager,
            shouldContinue: shouldContinue
        )
        if manifest.formatVersion == legacyFormatVersion, databasePayloadCount + blobPayloadCount == 0 {
            throw MacClippyBackupError.keyCompatibilityUnproven
        }
    }

    private static func authenticateKeyCheck(_ manifest: MacClippyBackupManifest, key: SymmetricKey) throws {
        guard let encoded = manifest.keyCheck, let combined = Data(base64Encoded: encoded) else {
            throw MacClippyBackupError.invalidManifest
        }
        do {
            let plaintext = try MacClippyCipher.open(MacClippyEnvelope(combined: combined), with: key)
            guard plaintext == keyCheckSentinel else { throw MacClippyBackupError.keyMismatch }
        } catch MacClippyCipherError.openFailed {
            throw MacClippyBackupError.keyMismatch
        } catch MacClippyCipherError.invalidEnvelope {
            throw MacClippyBackupError.invalidManifest
        }
    }

    private static func authenticateDatabasePayloads(
        _ key: SymmetricKey,
        snapshotURL: URL,
        shouldContinue: () -> Bool
    ) throws -> Int {
        var count = 0
        for name in ["clipboard", "pinboards", "snippets"] {
            try ensureContinues(shouldContinue)
            count += try authenticateDatabasePayloads(
                name,
                key: key,
                snapshotURL: snapshotURL,
                shouldContinue: shouldContinue
            )
        }
        return count
    }

    private static func authenticateDatabasePayloads(
        _ name: String,
        key: SymmetricKey,
        snapshotURL: URL,
        shouldContinue: () -> Bool
    ) throws -> Int {
        let databaseURL = snapshotURL.appendingPathComponent("\(name).sqlite")
        let database = try MacClippyDatabase(url: databaseURL, readOnly: true)
        do {
            let count = try database.queue.read { connection in
                try authenticatePayloadRows(connection, name: name, key: key, shouldContinue: shouldContinue)
            }
            try database.queue.close()
            return count
        } catch {
            try? database.queue.close()
            throw error
        }
    }

    private static func authenticatePayloadRows(
        _ connection: Database,
        name: String,
        key: SymmetricKey,
        shouldContinue: () -> Bool
    ) throws -> Int {
        let cursor = try Row.fetchCursor(connection, sql: encryptedPayloadQuery(for: name))
        var count = 0
        while let row = try cursor.next() {
            try ensureContinues(shouldContinue)
            guard let combined: Data = row[0] else { continue }
            try authenticateEnvelope(combined, key: key, fileName: "\(name).sqlite")
            count += 1
        }
        return count
    }

    private static func encryptedPayloadQuery(for name: String) -> String {
        switch name {
        case "clipboard":
            return """
                SELECT envelope FROM clipboard_records WHERE envelope IS NOT NULL
                UNION ALL
                SELECT payload FROM clipboard_representations WHERE payload IS NOT NULL
                """
        case "pinboards":
            return "SELECT envelope FROM macclippy_pinboards WHERE envelope IS NOT NULL"
        default:
            return "SELECT envelope FROM macclippy_snippets WHERE envelope IS NOT NULL"
        }
    }

    private static func authenticateBlobPayloads(
        _ key: SymmetricKey,
        snapshotURL: URL,
        fileManager: FileManager,
        shouldContinue: () -> Bool
    ) throws -> Int {
        let directory = snapshotURL.appendingPathComponent("blobs", isDirectory: true)
        var count = 0
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
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
            guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                  url.pathExtension == "bin" else { continue }
            let combined = try Data(contentsOf: url)
            try authenticateEnvelope(combined, key: key, fileName: "blobs/\(url.lastPathComponent)")
            count += 1
        }
        if let enumerationError { throw enumerationError }
        return count
    }

    private static func authenticateEnvelope(_ data: Data, key: SymmetricKey, fileName: String) throws {
        do {
            _ = try MacClippyCipher.open(MacClippyEnvelope(combined: data), with: key)
        } catch MacClippyCipherError.openFailed {
            throw MacClippyBackupError.keyMismatch
        } catch MacClippyCipherError.invalidEnvelope {
            throw MacClippyBackupError.checksumMismatch(fileName)
        }
    }

    private static func validateClipboardBlobReferences(
        _ key: SymmetricKey,
        manifest: MacClippyBackupManifest,
        snapshotURL: URL,
        shouldContinue: () -> Bool
    ) throws {
        let url = snapshotURL.appendingPathComponent("clipboard.sqlite")
        let database = try MacClippyDatabase(url: url, readOnly: true)
        let listedFiles = Set(manifest.files.map(\.relativePath))
        do {
            try database.queue.read { connection in
                try validateClipboardRecordReferences(
                    connection,
                    key: key,
                    listedFiles: listedFiles,
                    shouldContinue: shouldContinue
                )
                try validateRepresentationReferences(
                    connection,
                    listedFiles: listedFiles,
                    shouldContinue: shouldContinue
                )
            }
            try database.queue.close()
        } catch {
            try? database.queue.close()
            throw error
        }
    }

    private static func validateClipboardRecordReferences(
        _ connection: Database,
        key: SymmetricKey,
        listedFiles: Set<String>,
        shouldContinue: () -> Bool
    ) throws {
        let representationColumns = try Row.fetchAll(
            connection,
            sql: "PRAGMA table_info(clipboard_representations)"
        )
        let hasItemIndexColumn = representationColumns.contains { ($0["name"] as String?) == "item_index" }
        let recordColumns = try Row.fetchAll(
            connection,
            sql: "PRAGMA table_info(clipboard_records)"
        )
        let rosterColumn = recordColumns.contains { ($0["name"] as String?) == "representation_refs_auth" }
            ? "representation_refs_auth"
            : "NULL AS representation_refs_auth"
        let records = try Row.fetchCursor(
            connection,
            sql: "SELECT id, envelope, \(rosterColumn) FROM clipboard_records"
        )
        while let row = try records.next() {
            try ensureContinues(shouldContinue)
            guard let recordID: String = row["id"] else {
                throw MacClippyBackupError.checksumMismatch("clipboard.sqlite")
            }
            guard let envelope: Data = row["envelope"] else {
                throw MacClippyBackupError.checksumMismatch("clipboard.sqlite")
            }
            let decoded = try decodeClipboardRecord(envelope, key: key)
            let rosterEnvelope: Data? = row["representation_refs_auth"]
            if decoded.requiresRepresentationRoster || rosterEnvelope != nil {
                do {
                    try MacClippyRepresentationRosterCodec.validate(
                        recordID: recordID,
                        envelope: rosterEnvelope,
                        on: connection,
                        key: key,
                        maxRepresentations: MacClippyPasteboardInputLimits.default.maxRepresentationsPerRecord,
                        hasItemIndexColumn: hasItemIndexColumn
                    )
                } catch {
                    throw MacClippyBackupError.checksumMismatch("clipboard.sqlite")
                }
            }
            let record = decoded.record
            if let blobID = record.imageBlobID {
                try requireReferencedBlob(blobID, listedFiles: listedFiles)
            }
        }
    }

    private static func decodeClipboardRecord(
        _ envelope: Data,
        key: SymmetricKey
    ) throws -> MacClippyDecodedClipboardRecordEnvelope {
        let plaintext = try MacClippyCipher.open(MacClippyEnvelope(combined: envelope), with: key)
        do {
            return try MacClippyClipboardRecordEnvelopeCodec.decode(plaintext)
        } catch {
            throw MacClippyBackupError.checksumMismatch("clipboard.sqlite")
        }
    }

    private static func validateRepresentationReferences(
        _ connection: Database,
        listedFiles: Set<String>,
        shouldContinue: () -> Bool
    ) throws {
        let representations = try Row.fetchCursor(
            connection,
            sql: "SELECT blob_id FROM clipboard_representations WHERE blob_id IS NOT NULL"
        )
        while let row = try representations.next() {
            try ensureContinues(shouldContinue)
            guard let blobID: String = row["blob_id"] else {
                throw MacClippyBackupError.checksumMismatch("clipboard.sqlite")
            }
            try requireReferencedBlob(blobID, listedFiles: listedFiles)
        }
    }

    private static func requireReferencedBlob(_ blobID: String, listedFiles: Set<String>) throws {
        guard isSafeBlobIdentifier(blobID) else { throw MacClippyBackupError.invalidManifest }
        let path = "blobs/\(blobID).bin"
        guard listedFiles.contains(path) else { throw MacClippyBackupError.missingComponent(path) }
    }
}
