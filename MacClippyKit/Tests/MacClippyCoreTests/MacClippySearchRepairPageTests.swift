import Foundation
import GRDB
import XCTest

@testable import MacClippyCore

final class MacClippySearchRepairPageTests: XCTestCase {
    func testRepairPageKeepsActiveRowsAndUsesEpochToRejectConcurrentFailure() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let search = try SearchStore(database: database)
        let id = RecordID.generate()
        try search.insert(id: id, text: "old searchable text")
        try search.markRepairNeeded()
        let expectedEpoch = try search.repairEpoch()

        let report = try search.applyRepairPage([
            MacClippySearchDocument(id: id, text: "repaired searchable text")
        ])

        XCTAssertEqual(report.documentsWritten, 1)
        XCTAssertTrue(try search.repairNeeded())
        XCTAssertEqual(try search.search(query: "repaired", limit: 10).map(\.id), [id])
        XCTAssertTrue(try search.search(query: "old", limit: 10).isEmpty)
        try search.markRepairNeeded()
        XCTAssertFalse(try search.completeRepair(
            expectedEpoch: expectedEpoch,
            sourceProjectionVersion: SearchStore.currentSourceProjectionVersion
        ))
        XCTAssertTrue(try search.repairNeeded())
        XCTAssertTrue(try search.completeRepair(
            expectedEpoch: search.repairEpoch(),
            sourceProjectionVersion: SearchStore.currentSourceProjectionVersion
        ))
        XCTAssertFalse(try search.repairNeeded())
    }

    func testRepairPageRemovesEmptyDocumentAndMalformedProjectionRows() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let search = try SearchStore(database: database)
        let emptyID = RecordID.generate()
        let validID = RecordID.generate()
        try search.insert(id: emptyID, text: "stale empty projection")
        _ = try search.applyRepairPage([
            MacClippySearchDocument(id: emptyID, text: "  \n"),
            MacClippySearchDocument(id: validID, text: "valid projection")
        ])
        let rowID = try XCTUnwrap(try search.maximumProjectionRowID())
        try database.queue.write { connection in
            try connection.execute(
                sql: "INSERT INTO macclippy_search_index(rowid, kind, record_id, content) VALUES (?, ?, ?, ?)",
                arguments: [rowID + 1, RecordKind.clipboardItem.rawValue, RecordID.generate().rawValue, "unkeyed"]
            )
        }

        XCTAssertTrue(try search.search(query: "stale", limit: 10).isEmpty)
        XCTAssertEqual(try search.search(query: "valid", limit: 10).map(\.id), [validID])
        let malformed = try search.malformedProjectionRowIDs(
            afterRowID: nil,
            throughRowID: rowID + 1,
            limit: 1
        )
        XCTAssertEqual(malformed, [rowID + 1])
        try search.removeProjectionRows(rowIDs: malformed)
        XCTAssertTrue(try search.malformedProjectionRowIDs(
            afterRowID: nil,
            throughRowID: rowID + 1,
            limit: 1
        ).isEmpty)
    }
}
