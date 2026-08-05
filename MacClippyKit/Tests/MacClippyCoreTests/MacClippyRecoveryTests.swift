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

    func testSearchRepairNeededMarkerPersistsUntilCleared() throws {
        let search = try SearchStore(database: MacClippyDatabase(inMemory: true))

        XCTAssertFalse(search.repairNeeded())
        try search.markRepairNeeded()
        XCTAssertTrue(search.repairNeeded())
        try search.clearRepairNeeded()
        XCTAssertFalse(search.repairNeeded())
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
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
