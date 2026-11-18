import CryptoKit
import Foundation
import XCTest

@testable import MacClippyCore

final class MacClippyRecoveryTests: XCTestCase {
    func testDatabaseHealthReportsHealthyAndMissingSchema() throws {
        let database = try MacClippyDatabase(inMemory: true)
        try database.queue.write { connection in
            try connection.execute(sql: "CREATE TABLE required_table(id INTEGER PRIMARY KEY)")
        }

        let healthy = database.healthCheck(requiredTables: ["required_table"], mode: .full)
        XCTAssertEqual(healthy.status, .healthy)
        XCTAssertTrue(healthy.quickCheckPassed)
        XCTAssertTrue(healthy.issues.isEmpty)

        let missing = database.healthCheck(requiredTables: ["required_table", "missing_table"], mode: .full)
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

        let health = search.databaseHealth(mode: .full)
        XCTAssertEqual(health.status, .repairable)
        XCTAssertTrue(health.issues.contains("fts-row-without-key"))
        XCTAssertEqual(health.fullIntegrityCheckPassed, true)
        XCTAssertEqual(health.foreignKeyCheckPerformed, true)
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

        let health = search.databaseHealth(mode: .full)
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

        let health = search.databaseHealth(mode: .full)
        XCTAssertEqual(health.status, .repairable)
        XCTAssertTrue(health.issues.contains("fts-projection-key-mismatch"))
    }
}
