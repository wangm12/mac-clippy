import CryptoKit
import Foundation
import GRDB
import XCTest

@testable import MacClippyCore

final class MacClippySearchMaintenanceIndexTests: XCTestCase {
    private let rowIDIndex = "macclippy_search_keys_rowid_idx"
    private let keysetIndex = "macclippy_search_keys_kind_rowid_record_id_idx"

    func testMigrationPreservesSearchAndDeletionKeysetBehaviorWithIndexes() throws {
        let database = try legacyDatabase()
        let ids = (0..<4).map { _ in RecordID.generate() }
        try seedValidRows(ids: ids, rowIDs: [10, 20, 30, 40], in: database)

        try database.migrate(SearchStore.migrations)
        let search = try SearchStore(database: database)
        XCTAssertFalse(try search.repairNeeded())
        XCTAssertEqual(
            Set(try search.search(kind: nil, query: "needle", limit: 10).map(\.id)),
            Set(ids)
        )

        let firstPage = try search.indexedRecordIDPage(limit: 2)
        XCTAssertEqual(firstPage.map(\.id), Array(ids.prefix(2)))
        XCTAssertEqual(firstPage.map(\.rowID), [10, 20])
        try delete(firstPage, from: database)

        let nextPage = try search.indexedRecordIDPage(afterRowID: firstPage.last?.rowID, limit: 2)
        XCTAssertEqual(nextPage.map(\.id), Array(ids.suffix(2)))
        XCTAssertEqual(nextPage.map(\.rowID), [30, 40])
        XCTAssertEqual(
            Set(try search.search(kind: nil, query: "needle", limit: 10).map(\.id)),
            Set(ids.suffix(2))
        )

        let keysetPlan = try explain(
            """
            SELECT record_id, rowid FROM macclippy_search_keys
            WHERE kind = ? AND rowid > ? ORDER BY rowid ASC LIMIT ?
            """,
            arguments: [RecordKind.clipboardItem.rawValue, Int64(20), 2],
            in: database
        )
        let lookupPlan = try explain(
            "SELECT record_id FROM macclippy_search_keys WHERE rowid = ?",
            arguments: [Int64(30)],
            in: database
        )
        let deletePlan = try explain(
            "DELETE FROM macclippy_search_keys WHERE rowid = ?",
            arguments: [Int64(30)],
            in: database
        )

        assertIndexedPlan(keysetPlan, using: keysetIndex, covering: true)
        assertIndexedPlan(lookupPlan, using: rowIDIndex)
        assertIndexedPlan(deletePlan, using: rowIDIndex)
    }

    func testDuplicateLegacyRowIDsResetDerivedSearchIndexAndMarkRepairNeeded() throws {
        let authoritativeStore = try clipboardStore()
        let authoritativeRecord = try authoritativeStore.append(.text("source of truth"))
        let database = try legacyDatabase()
        let indexedID = RecordID.generate()
        let conflictingID = RecordID.generate()
        try database.queue.write { connection in
            try Self.insertIndexRow(
                rowID: 77,
                kind: .clipboardItem,
                id: indexedID,
                text: "duplicate legacy rowid content",
                in: connection
            )
            try Self.insertKeyRow(rowID: 77, kind: .clipboardItem, id: indexedID, in: connection)
            try Self.insertKeyRow(rowID: 77, kind: .clipboardItem, id: conflictingID, in: connection)
        }

        try database.migrate(SearchStore.migrations)
        let search = try SearchStore(database: database)

        XCTAssertTrue(try search.repairNeeded())
        XCTAssertEqual(try search.indexRevision(), 1)
        XCTAssertEqual(try projectionCounts(in: database).index, 0)
        XCTAssertEqual(try projectionCounts(in: database).keys, 0)
        XCTAssertTrue(try search.search(kind: nil, query: "duplicate", limit: 10).isEmpty)
        XCTAssertEqual(try authoritativeStore.body(for: authoritativeRecord.id), .text("source of truth"))
    }

    func testMismatchedLegacyProjectionIsClearedInsteadOfReassigned() throws {
        let database = try legacyDatabase()
        let indexID = RecordID.generate()
        let keyID = RecordID.generate()
        try database.queue.write { connection in
            try Self.insertIndexRow(
                rowID: 81,
                kind: .clipboardItem,
                id: indexID,
                text: "belongs to index id",
                in: connection
            )
            try Self.insertKeyRow(rowID: 81, kind: .clipboardItem, id: keyID, in: connection)
        }

        try database.migrate(SearchStore.migrations)
        let search = try SearchStore(database: database)

        XCTAssertTrue(try search.repairNeeded())
        XCTAssertTrue(try search.search(kind: nil, query: "belongs", limit: 10).isEmpty)
        XCTAssertEqual(try projectionCounts(in: database).index, 0)
        XCTAssertEqual(try projectionCounts(in: database).keys, 0)
    }

    func testBoundedHealthSkipsProjectionScanAndFullHealthFindsMismatch() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let search = try SearchStore(database: database)
        let indexedID = RecordID.generate()
        try search.insert(id: indexedID, text: "projection health")
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE macclippy_search_index SET record_id = ? WHERE record_id = ?",
                arguments: [RecordID.generate().rawValue, indexedID.rawValue]
            )
        }

        let boundedHealth = search.databaseHealth()
        XCTAssertEqual(boundedHealth.status, .healthy)
        XCTAssertTrue(boundedHealth.issues.contains("fts-projection-integrity-not-checked"))
        XCTAssertFalse(boundedHealth.issues.contains("fts-projection-key-mismatch"))

        let fullHealth = search.databaseHealth(mode: .full)
        XCTAssertEqual(fullHealth.status, .repairable)
        XCTAssertTrue(fullHealth.issues.contains("fts-projection-key-mismatch"))
    }

    func testMigrationReplayAndReopenAreIdempotent() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-maintenance-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")
            try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
        }

        let id = RecordID.generate()
        do {
            let database = try MacClippyDatabase(url: databaseURL, migrations: legacyMigrations())
            try seedValidRows(ids: [id], rowIDs: [91], in: database)
            try database.migrate(SearchStore.migrations)
            try database.migrate(SearchStore.migrations)
            let search = try SearchStore(database: database)
            XCTAssertEqual(try search.indexedRecordIDPage(limit: 1).map(\.id), [id])
            XCTAssertFalse(try search.repairNeeded())
        }

        do {
            let database = try MacClippyDatabase(url: databaseURL, migrations: SearchStore.migrations)
            let search = try SearchStore(database: database)
            XCTAssertEqual(try search.search(query: "needle", limit: 10).map(\.id), [id])
            XCTAssertEqual(try search.indexedRecordIDPage(limit: 1).map(\.rowID), [91])
            XCTAssertFalse(try search.repairNeeded())
        }
    }

    private func legacyDatabase() throws -> MacClippyDatabase {
        try MacClippyDatabase(url: URL(fileURLWithPath: ":memory:"), migrations: legacyMigrations())
    }

    private func legacyMigrations() -> [MacClippyDatabaseMigration] {
        Array(SearchStore.migrations.prefix(4))
    }

    private func seedValidRows(ids: [RecordID], rowIDs: [Int64], in database: MacClippyDatabase) throws {
        try database.queue.write { connection in
            for (id, rowID) in zip(ids, rowIDs) {
                try Self.insertIndexRow(
                    rowID: rowID,
                    kind: .clipboardItem,
                    id: id,
                    text: "needle searchable row \(rowID)",
                    in: connection
                )
                try Self.insertKeyRow(rowID: rowID, kind: .clipboardItem, id: id, in: connection)
            }
        }
    }

    private static func insertIndexRow(
        rowID: Int64,
        kind: RecordKind,
        id: RecordID,
        text: String,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO macclippy_search_index(rowid, kind, record_id, content)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [rowID, kind.rawValue, id.rawValue, text]
        )
    }

    private static func insertKeyRow(
        rowID: Int64,
        kind: RecordKind,
        id: RecordID,
        in database: Database
    ) throws {
        try database.execute(
            sql: "INSERT INTO macclippy_search_keys(kind, record_id, rowid) VALUES (?, ?, ?)",
            arguments: [kind.rawValue, id.rawValue, rowID]
        )
    }

    private func delete(_ page: [MacClippyIndexedRecordID], from database: MacClippyDatabase) throws {
        try database.queue.write { connection in
            for item in page {
                try connection.execute(
                    sql: "DELETE FROM macclippy_search_index WHERE rowid = ?",
                    arguments: [item.rowID]
                )
                try connection.execute(
                    sql: "DELETE FROM macclippy_search_keys WHERE rowid = ?",
                    arguments: [item.rowID]
                )
            }
        }
    }

    private func explain(
        _ statement: String,
        arguments: [Any] = [],
        in database: MacClippyDatabase
    ) throws -> [String] {
        guard let statementArguments = StatementArguments(arguments) else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        return try database.queue.read { connection in
            try Row.fetchAll(
                connection,
                sql: "EXPLAIN QUERY PLAN \(statement)",
                arguments: statementArguments
            ).map { row in
                let detail: String = row["detail"]
                return detail
            }
        }
    }

    private func assertIndexedPlan(
        _ details: [String],
        using indexName: String,
        covering: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let plan = details.joined(separator: " ").uppercased()
        XCTAssertTrue(plan.contains("SEARCH"), plan, file: file, line: line)
        XCTAssertTrue(plan.contains(indexName.uppercased()), plan, file: file, line: line)
        XCTAssertFalse(plan.contains("SCAN MACCLIPPY_SEARCH_KEYS"), plan, file: file, line: line)
        XCTAssertFalse(plan.contains("USE TEMP B-TREE"), plan, file: file, line: line)
        if covering {
            XCTAssertTrue(plan.contains("USING COVERING INDEX"), plan, file: file, line: line)
        }
    }

    private func projectionCounts(in database: MacClippyDatabase) throws -> (index: Int, keys: Int) {
        try database.queue.read { connection in
            (
                try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM macclippy_search_index") ?? 0,
                try Int.fetchOne(connection, sql: "SELECT COUNT(*) FROM macclippy_search_keys") ?? 0
            )
        }
    }

    private func clipboardStore() throws -> ClipboardStore {
        try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: SymmetricKey(data: Data(repeating: 9, count: 32)),
            deviceID: try XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
    }
}
