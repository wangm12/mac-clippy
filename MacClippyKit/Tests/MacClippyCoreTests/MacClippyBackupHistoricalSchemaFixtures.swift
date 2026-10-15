import CryptoKit
import Foundation
import GRDB

@testable import MacClippyCore

enum MacClippyBackupHistoricalSchemaFixture {
    static let historicalRecordID = "01K62V8MPW0000000000000000"
    static let historicalImageRecordID = "01K62V8MPW0000000000000001"
    static let historicalImageBlobID = "legacy-image"
    static let historicalSpillBlobID = "legacy-spill"
    static let historicalImageBytes = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0xF4, 0x22, 0x7F, 0x8A, 0x00, 0x00, 0x00,
        0x0E, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x42, 0xFF, 0x01, 0x0F, 0xF9, 0x03, 0xFD, 0x85, 0x11, 0x99, 0x76, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
    ])
    static let historicalSpillBytes = Data(repeating: 0x5A, count: 4_096)

    private static let databaseNames = ["clipboard", "search", "pinboards", "snippets"]

    static func makeMigration008Backup(in root: URL, key: SymmetricKey) throws -> URL {
        let databaseURLs = Dictionary(uniqueKeysWithValues: databaseNames.map { name in
            (name, root.appendingPathComponent("\(name).sqlite"))
        })
        try createHistoricalDatabases(at: databaseURLs, key: key)
        let sourceBlobs = try makeHistoricalBlobs(in: root, key: key)
        for databaseURL in databaseURLs.values {
            try MacClippyBackup.normalize(databaseURL)
        }
        return try writeSnapshot(in: root, databases: databaseURLs, blobs: sourceBlobs)
    }

    static func makePriorLiveRoot(at rootURL: URL, key: SymmetricKey) throws {
        let databasesURL = rootURL.appendingPathComponent("databases", isDirectory: true)
        try FileManager.default.createDirectory(at: databasesURL, withIntermediateDirectories: true)
        let clipboardDatabase = try MacClippyDatabase(
            url: databasesURL.appendingPathComponent("clipboard.sqlite"),
            migrations: MacClippyClipboardStore.migrations
        )
        let clipboard = try ClipboardStore(database: clipboardDatabase, deviceKey: key)
        _ = try clipboard.append(.text("prior live data"))
        try clipboardDatabase.queue.close()

        let liveMigrations = [
            ("search", MacClippySearchStore.migrations),
            ("pinboards", MacClippyPinboardStore.migrations),
            ("snippets", MacClippySnippetStore.migrations)
        ]
        for (name, migrations) in liveMigrations {
            let database = try MacClippyDatabase(
                url: databasesURL.appendingPathComponent("\(name).sqlite"),
                migrations: migrations
            )
            try database.queue.close()
        }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("blobs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent(MacClippyThumbnailCachePolicy.directoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    static func readClipboardStore(at rootURL: URL, key: SymmetricKey) throws -> ClipboardStore {
        let database = try MacClippyDatabase(
            url: rootURL.appendingPathComponent("databases/clipboard.sqlite"),
            migrations: MacClippyClipboardStore.migrations
        )
        return try ClipboardStore(database: database, deviceKey: key)
    }

    static func readSearchStore(at rootURL: URL) throws -> MacClippySearchStore {
        let database = try MacClippyDatabase(
            url: rootURL.appendingPathComponent("databases/search.sqlite"),
            migrations: MacClippySearchStore.migrations
        )
        return try MacClippySearchStore(database: database)
    }

    static func snapshotBytes(at snapshotURL: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: snapshotURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relativePath = String(url.path.dropFirst(snapshotURL.path.count + 1))
            result[relativePath] = try Data(contentsOf: url)
        }
        return result
    }

    private static func createHistoricalDatabases(at urls: [String: URL], key: SymmetricKey) throws {
        let clipboardDatabase = try MacClippyDatabase(
            url: databaseURL("clipboard", in: urls),
            migrations: Array(MacClippyClipboardStore.migrations.prefix(8))
        )
        try HistoricalRecordFixture.insertText(on: clipboardDatabase.queue, key: key)
        try HistoricalRecordFixture.insertImage(on: clipboardDatabase.queue, key: key)
        try clipboardDatabase.queue.close()

        let searchDatabase = try MacClippyDatabase(
            url: databaseURL("search", in: urls),
            migrations: baselineSearchMigrations()
        )
        try HistoricalRecordFixture.insertSearchRow(on: searchDatabase.queue)
        try searchDatabase.queue.close()

        // Pinboards and snippets are empty current-schema companions; this fixture claims historical coverage
        // only for the clipboard migration 008 database and baseline search schema/data.
        let currentDatabases = [
            ("pinboards", MacClippyPinboardStore.migrations),
            ("snippets", MacClippySnippetStore.migrations)
        ]
        for (name, migrations) in currentDatabases {
            let database = try MacClippyDatabase(url: databaseURL(name, in: urls), migrations: migrations)
            try database.queue.close()
        }
    }

    private static func makeHistoricalBlobs(in root: URL, key: SymmetricKey) throws -> BlobStore {
        let blobs = try BlobStore(
            rootURL: root.appendingPathComponent("legacy-blobs", isDirectory: true),
            key: key
        )
        try blobs.write(historicalImageBytes, id: historicalImageBlobID)
        try blobs.write(historicalSpillBytes, id: historicalSpillBlobID)
        return blobs
    }

    private static func baselineSearchMigrations() -> [MacClippyDatabaseMigration] {
        // These four migration bodies are copied from base commit 79e987a; later search migrations are not
        // applied until MacClippySearchStore opens the restored database in the test.
        [
            MacClippyDatabaseMigration(identifier: "001-search-core") { database in
                try database.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS macclippy_search_index USING fts5(
                        kind UNINDEXED, record_id UNINDEXED, content, tokenize = 'porter unicode61'
                    );
                    CREATE TABLE IF NOT EXISTS macclippy_search_keys(
                        kind TEXT NOT NULL, record_id TEXT NOT NULL, rowid INTEGER NOT NULL,
                        PRIMARY KEY(kind, record_id)
                    );
                """)
            },
            MacClippyDatabaseMigration(identifier: "002-search-repair-state") { database in
                try database.execute(sql: """
                    CREATE TABLE IF NOT EXISTS macclippy_search_state(
                        key TEXT PRIMARY KEY NOT NULL,
                        value INTEGER NOT NULL
                    );
                    INSERT OR IGNORE INTO macclippy_search_state(key, value)
                        VALUES ('repair_needed', 0);
                """)
            },
            MacClippyDatabaseMigration(identifier: "003-search-index-revision") { database in
                try database.execute(sql: """
                    INSERT OR IGNORE INTO macclippy_search_state(key, value)
                        VALUES ('index_revision', 0);
                """)
            },
            MacClippyDatabaseMigration(identifier: "004-source-projection") { database in
                try database.execute(sql: """
                    INSERT OR IGNORE INTO macclippy_search_state(key, value)
                        VALUES ('source_projection_version', 0);
                """)
            }
        ]
    }

    private static func writeSnapshot(in root: URL, databases: [String: URL], blobs: BlobStore) throws -> URL {
        let snapshotURL = root.appendingPathComponent("migration-008-backup", isDirectory: true)
        let snapshotBlobsURL = snapshotURL.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshotBlobsURL, withIntermediateDirectories: true)
        var files: [MacClippyBackupManifest.FileEntry] = []
        for name in databaseNames {
            let sourceURL = try databaseURL(name, in: databases)
            let destinationURL = snapshotURL.appendingPathComponent("\(name).sqlite")
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            files.append(try manifestEntry(for: destinationURL, relativePath: destinationURL.lastPathComponent))
        }
        try copyBlob(historicalImageBlobID, from: blobs, to: snapshotBlobsURL, files: &files)
        try copyBlob(historicalSpillBlobID, from: blobs, to: snapshotBlobsURL, files: &files)

        let manifest = MacClippyBackupManifest(
            formatVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_000),
            databaseNames: databaseNames,
            files: files
        )
        let manifestURL = snapshotURL.appendingPathComponent(MacClippyBackup.manifestFileName)
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        return snapshotURL
    }

    private static func copyBlob(
        _ id: String,
        from blobs: BlobStore,
        to destinationDirectory: URL,
        files: inout [MacClippyBackupManifest.FileEntry]
    ) throws {
        let sourceURL = try blobs.encryptedURL(id: id)
        let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        let relativePath = "blobs/\(destinationURL.lastPathComponent)"
        files.append(try manifestEntry(for: destinationURL, relativePath: relativePath))
    }

    private static func manifestEntry(for url: URL, relativePath: String) throws -> MacClippyBackupManifest.FileEntry {
        let data = try Data(contentsOf: url)
        return MacClippyBackupManifest.FileEntry(
            relativePath: relativePath,
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func databaseURL(_ name: String, in urls: [String: URL]) throws -> URL {
        guard let url = urls[name] else { throw CocoaError(.fileNoSuchFile) }
        return url
    }
}

private enum HistoricalRecordFixture {
    static func insertText(on queue: DatabaseQueue, key: SymmetricKey) throws {
        let payload = try JSONEncoder().encode(ClipboardRecord.text("migration 008 historical body"))
        try insertRecord(
            LegacyRecord(
                id: MacClippyBackupHistoricalSchemaFixture.historicalRecordID,
                contentKind: .text,
                preview: "migration 008 historical body",
                primaryBlobID: nil,
                envelope: try MacClippyCipher.seal(payload, with: key).combined
            ),
            on: queue
        )
    }

    static func insertImage(on queue: DatabaseQueue, key: SymmetricKey) throws {
        let recordID = MacClippyBackupHistoricalSchemaFixture.historicalImageRecordID
        let imagePayload = try JSONEncoder().encode(ClipboardRecord.image(
            blobID: MacClippyBackupHistoricalSchemaFixture.historicalImageBlobID,
            width: 2,
            height: 1
        ))
        let inlineEnvelope = try MacClippyCipher.seal(
            MacClippyBackupHistoricalSchemaFixture.historicalImageBytes,
            with: key
        )
        try insertRecord(
            LegacyRecord(
                id: recordID,
                contentKind: .image,
                preview: "historical image",
                primaryBlobID: MacClippyBackupHistoricalSchemaFixture.historicalImageBlobID,
                envelope: try MacClippyCipher.seal(imagePayload, with: key).combined
            ),
            on: queue
        )
        try queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO clipboard_representations
                        (record_id, sort_order, uti, payload, blob_id, payload_state)
                    VALUES (?, 0, 'public.png', ?, NULL, 'present'),
                           (?, 1, 'com.example.legacy-spill', NULL, ?, 'spilled')
                    """,
                arguments: [
                    recordID,
                    inlineEnvelope.combined,
                    recordID,
                    MacClippyBackupHistoricalSchemaFixture.historicalSpillBlobID
                ]
            )
        }
    }

    static func insertSearchRow(on queue: DatabaseQueue) throws {
        let recordID = MacClippyBackupHistoricalSchemaFixture.historicalRecordID
        let kind = RecordKind.clipboardItem.rawValue
        let rowID: Int64 = 1
        try queue.write { database in
            try database.execute(
                sql: "INSERT INTO macclippy_search_index (rowid, kind, record_id, content) VALUES (?, ?, ?, ?)",
                arguments: [rowID, kind, recordID, "migration needle historical"]
            )
            try database.execute(
                sql: "INSERT INTO macclippy_search_keys (kind, record_id, rowid) VALUES (?, ?, ?)",
                arguments: [kind, recordID, rowID]
            )
        }
    }

    private static func insertRecord(_ record: LegacyRecord, on queue: DatabaseQueue) throws {
        try queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO clipboard_records
                        (id, created, modified, device_id, lamport, kind, content_kind, preview, envelope,
                         source_app_name, primary_blob_id)
                    VALUES (?, ?, ?, ?, ?, 'clipboardItem', ?, ?, ?, NULL, ?)
                    """,
                arguments: [
                    record.id,
                    Int64(1_000),
                    Int64(1_000),
                    DeviceID.generate().rawValue,
                    Int64(1),
                    record.contentKind.rawValue,
                    record.preview,
                    record.envelope,
                    record.primaryBlobID
                ]
            )
        }
    }

    private struct LegacyRecord {
        let id: String
        let contentKind: MacClippyContentKind
        let preview: String
        let primaryBlobID: String?
        let envelope: Data
    }
}
