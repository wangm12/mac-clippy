import CryptoKit
import Foundation
import XCTest

import MacClippyCore

final class MacClippyRecoveryTests: XCTestCase {
    func testDatabaseHealthReportsHealthyAndMissingSchema() throws {
        let database = try MacClippyDatabase(inMemory: true)
        try database.queue.write { connection in
            try connection.execute(sql: "CREATE TABLE required_table(id INTEGER PRIMARY KEY)")
        }

        let healthy = database.healthCheck(requiredTables: ["required_table"])
        XCTAssertEqual(healthy.status, .healthy)
        XCTAssertTrue(healthy.quickCheckPassed)
        XCTAssertTrue(healthy.issues.isEmpty)

        let missing = database.healthCheck(requiredTables: ["required_table", "missing_table"])
        XCTAssertEqual(missing.status, .unrecoverable)
        XCTAssertEqual(missing.missingTables, ["missing_table"])
        XCTAssertTrue(missing.issues.contains("missing-required-tables"))
    }

    func testSearchRepairRebuildsAndCancellationRollsBack() throws {
        let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
        let oldID = RecordID.generate()
        let stableID = RecordID.generate()
        let newID = RecordID.generate()
        try search.insert(id: oldID, text: "old searchable text")
        try search.insert(id: stableID, text: "stable searchable text")

        let report = try search.rebuild(documents: [
            MacClippySearchDocument(id: stableID, text: "stable searchable text"),
            MacClippySearchDocument(id: newID, text: "new searchable text")
        ])
        XCTAssertEqual(report.documentsWritten, 2)
        XCTAssertEqual(report.failedDocuments, 0)
        XCTAssertTrue(try search.search(query: "old", limit: 10).isEmpty)
        XCTAssertEqual(try search.search(query: "new", limit: 10).map(\.id), [newID])

        XCTAssertThrowsError(try search.rebuild(
            documents: [MacClippySearchDocument(id: RecordID.generate(), text: "cancelled")],
            shouldCancel: { true }
        )) { error in
            XCTAssertEqual(error as? MacClippySearchRepairError, .cancelled)
        }
        XCTAssertEqual(try search.search(query: "stable", limit: 10).map(\.id), [stableID])
        XCTAssertEqual(try search.search(query: "new", limit: 10).map(\.id), [newID])
    }

    func testSearchRepairContinuesAfterAnEmptyPage() throws {
        let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
        let id = RecordID.generate()
        var pageIndex = 0

        let report = try search.rebuild(pages: {
            defer { pageIndex += 1 }
            switch pageIndex {
            case 0: return []
            case 1: return [MacClippySearchDocument(id: id, text: "healthy later page")]
            default: return nil
            }
        })

        XCTAssertEqual(report.documentsWritten, 1)
        XCTAssertEqual(try search.search(query: "healthy", limit: 10).map(\.id), [id])
    }

    func testSearchRepairNeededMarkerPersistsUntilCleared() throws {
        let search = try SearchStore(database: MacClippyDatabase(inMemory: true))

        XCTAssertFalse(try search.repairNeeded())
        try search.markRepairNeeded()
        XCTAssertTrue(try search.repairNeeded())
        try search.clearRepairNeeded()
        XCTAssertFalse(try search.repairNeeded())
    }

    func testSearchHealthDetectsFTSRowWithoutProjectionKey() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let search = try SearchStore(database: database)
        let id = RecordID.generate()
        try search.insert(id: id, text: "health check")

        try database.queue.write { connection in
            try connection.execute(
                sql: "DELETE FROM macclippy_search_keys WHERE record_id = ?",
                arguments: [id.rawValue]
            )
        }

        let health = search.databaseHealth()
        XCTAssertEqual(health.status, .repairable)
        XCTAssertTrue(health.issues.contains("fts-row-without-key"))
    }

    func testSearchRepairRemovesOrphanFTSRowsWithoutProjectionKeys() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let search = try SearchStore(database: database)
        let id = RecordID.generate()
        try search.insert(id: id, text: "orphan projection")
        try database.queue.write { connection in
            try connection.execute(
                sql: "DELETE FROM macclippy_search_keys WHERE record_id = ?",
                arguments: [id.rawValue]
            )
        }

        _ = try search.rebuild(documents: [])

        let health = search.databaseHealth()
        XCTAssertEqual(health.status, .healthy)
        let rowCount = try database.queue.read { connection in
            try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM macclippy_search_index")
        }
        XCTAssertEqual(rowCount, 0)
    }

    func testSearchRepairRemovesKindMismatchFromBothProjectionSides() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let search = try SearchStore(database: database)
        let id = RecordID.generate()
        try search.insert(id: id, text: "mismatched kind")

        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE macclippy_search_index SET kind = ? WHERE record_id = ?",
                arguments: [RecordKind.pinboard.rawValue, id.rawValue]
            )
        }

        _ = try search.rebuild(documents: [])

        XCTAssertEqual(search.databaseHealth().status, .healthy)
        let counts = try database.queue.read { connection in
            (
                try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM macclippy_search_index"),
                try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM macclippy_search_keys")
            )
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }

    func testSearchHealthDetectsInvalidProjectionKeyInsteadOfDroppingIt() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let search = try SearchStore(database: database)
        let id = RecordID.generate()

        try search.insert(id: id, text: "invalid kind")
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE macclippy_search_keys SET kind = ? WHERE record_id = ?",
                arguments: ["not-a-record-kind", id.rawValue]
            )
        }

        let health = search.databaseHealth()
        XCTAssertEqual(health.status, .repairable)
        XCTAssertTrue(health.issues.contains("fts-invalid-projection-key"))
    }

    func testSearchHealthDetectsProjectionKeyMismatch() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let search = try SearchStore(database: database)
        let id = RecordID.generate()

        try search.insert(id: id, text: "mismatched projection")
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE macclippy_search_index SET record_id = ? WHERE record_id = ?",
                arguments: [RecordID.generate().rawValue, id.rawValue]
            )
        }

        let health = search.databaseHealth()
        XCTAssertEqual(health.status, .repairable)
        XCTAssertTrue(health.issues.contains("fts-projection-key-mismatch"))
    }

    func testBackupValidationAndRestorePreserveDatabaseAndBlobEvidence() throws {
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let clipboardDatabase = try MacClippyDatabase(inMemory: true)
        let clipboard = try ClipboardStore(database: clipboardDatabase, deviceKey: key)
        let searchDatabase = try MacClippyDatabase(inMemory: true)
        let search = try SearchStore(database: searchDatabase)
        let pinboardDatabase = try MacClippyDatabase(inMemory: true)
        _ = try PinboardStore(database: pinboardDatabase, deviceKey: key)
        let snippetDatabase = try MacClippyDatabase(inMemory: true)
        _ = try SnippetStore(database: snippetDatabase, deviceKey: key)

        let meta = try clipboard.append(.text("backup-safe-test"))
        try search.insert(id: meta.id, text: "backup-safe-test")

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobsURL = root.appendingPathComponent("blobs", isDirectory: true)
        let blobs = try BlobStore(rootURL: blobsURL, key: key)
        let blobID = try blobs.write(Data(repeating: 8, count: 32))
        let snapshotURL = root.appendingPathComponent("snapshot", isDirectory: true)

        let manifest = try MacClippyBackup.create(
            sources: [
                MacClippyBackupSource(name: "clipboard", database: clipboardDatabase),
                MacClippyBackupSource(name: "search", database: searchDatabase),
                MacClippyBackupSource(name: "pinboards", database: pinboardDatabase),
                MacClippyBackupSource(name: "snippets", database: snippetDatabase)
            ],
            blobsURL: blobsURL,
            at: snapshotURL
        )
        XCTAssertEqual(manifest.databaseNames, ["clipboard", "pinboards", "search", "snippets"])
        XCTAssertTrue(manifest.files.contains { $0.relativePath == "blobs/\(blobID).bin" })

        let validation = try MacClippyBackup.validate(at: snapshotURL)
        XCTAssertEqual(validation.databaseHealth["clipboard"]?.status, .healthy)
        XCTAssertEqual(validation.databaseHealth["search"]?.status, .healthy)
        XCTAssertEqual(validation.databaseRowCounts["clipboard"], 1)
        XCTAssertEqual(validation.databaseRowCounts["search"], 1)

        let restoredURL = root.appendingPathComponent("restored", isDirectory: true)
        let restored = try MacClippyBackup.restore(from: snapshotURL, to: restoredURL)
        XCTAssertEqual(restored.databaseRowCounts, validation.databaseRowCounts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredURL.appendingPathComponent("blobs/\(blobID).bin").path))

        let liveRoot = root.appendingPathComponent("live", isDirectory: true)
        try FileManager.default.createDirectory(
            at: liveRoot.appendingPathComponent("databases", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("stale".utf8).write(to: liveRoot.appendingPathComponent("databases/clipboard.sqlite"))
        try FileManager.default.createDirectory(
            at: liveRoot.appendingPathComponent("thumbnails", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("thumb".utf8).write(to: liveRoot.appendingPathComponent("thumbnails/old.bin"))

        let installed = try MacClippyBackup.installIntoLiveRoot(from: snapshotURL, liveRootURL: liveRoot)
        XCTAssertEqual(installed.databaseRowCounts, validation.databaseRowCounts)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: liveRoot.appendingPathComponent("databases/clipboard.sqlite").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: liveRoot.appendingPathComponent("blobs/\(blobID).bin").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: liveRoot.appendingPathComponent("thumbnails/old.bin").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: liveRoot.appendingPathComponent("clipboard.sqlite").path
            )
        )
    }

    func testBackupValidationRejectsManifestPathTraversal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = MacClippyBackupManifest(
            formatVersion: 1,
            createdAt: Date(),
            databaseNames: ["clipboard"],
            files: [
                .init(relativePath: "../outside.sqlite", byteCount: 0, sha256: "")
            ]
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: root.appendingPathComponent(MacClippyBackup.manifestFileName))

        XCTAssertThrowsError(try MacClippyBackup.validate(at: root)) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .invalidManifest)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
