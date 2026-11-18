import CryptoKit
import GRDB
import XCTest

@testable import MacClippyCore

final class MacClippyClipboardRecordsRevisionTests: XCTestCase {
    func testRecordAndRepresentationMutationsChangeRevisionWhileAuthenticationIsStable() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(
            database: database, deviceKey: SymmetricKey(data: Data(repeating: 33, count: 32))
        )
        let initial = try store.recordsRevision()
        let meta = try store.append(.text("revision body"), representations: [
            MacClippyClipboardRepresentation(uti: "com.example.extra", payloadBytes: Data([1, 2, 3]))
        ])
        var revision = try store.recordsRevision()
        XCTAssertGreaterThan(revision, initial)
        try store.authenticateOwnedBlobReferenceIndexForRetention()
        try store.authenticateRetentionCandidates([meta.id])
        XCTAssertEqual(try store.recordsRevision(), revision, "authentication must not invalidate its own snapshot")

        _ = try store.setCustomLabel(id: meta.id, label: "new label")
        XCTAssertGreaterThan(try store.recordsRevision(), revision)
        revision = try store.recordsRevision()
        try store.setOCRText(id: meta.id, text: "new OCR")
        XCTAssertGreaterThan(try store.recordsRevision(), revision)
        revision = try store.recordsRevision()
        _ = try store.update(id: meta.id, with: .text("revision body with a larger payload"))
        XCTAssertGreaterThan(try store.recordsRevision(), revision)
        revision = try store.recordsRevision()
        try store.deleteRepresentations(for: meta.id)
        XCTAssertGreaterThan(try store.recordsRevision(), revision)
        revision = try store.recordsRevision()
        try store.delete(id: meta.id)
        XCTAssertGreaterThan(try store.recordsRevision(), revision)
    }

    func testFootprintSQLMutationsInvalidateRevisionButNoOpUpdatesDoNot() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(
            database: database, deviceKey: SymmetricKey(data: Data(repeating: 35, count: 32))
        )
        let meta = try store.append(.text("same preview"), representations: [
            MacClippyClipboardRepresentation(uti: "com.example.extra", payloadBytes: Data([7]))
        ])
        let revision = try store.recordsRevision()
        try database.queue.write { connection in
            try connection.execute(sql: "UPDATE clipboard_records SET primary_blob_id = primary_blob_id")
            try connection.execute(sql: "UPDATE clipboard_representations SET payload = payload, blob_id = blob_id")
        }
        XCTAssertEqual(try store.recordsRevision(), revision)
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_representations SET payload = ? WHERE record_id = ?",
                arguments: [Data([7, 8, 9]), meta.id.rawValue]
            )
        }
        XCTAssertGreaterThan(try store.recordsRevision(), revision)
    }

    func testUpgradeCreatesRevisionAndReopeningPreservesIt() throws {
        let database = try MacClippyDatabase(inMemory: true)
        try database.migrate(Array(ClipboardStore.migrations.prefix(12)))
        let key = SymmetricKey(data: Data(repeating: 37, count: 32))
        let store = try ClipboardStore(database: database, deviceKey: key)
        XCTAssertEqual(try store.recordsRevision(), 0)
        let meta = try store.append(.text("upgrade body"))
        let revision = try store.recordsRevision()
        let reopened = try ClipboardStore(database: database, deviceKey: key)
        XCTAssertEqual(try reopened.body(for: meta.id), .text("upgrade body"))
        XCTAssertEqual(try reopened.recordsRevision(), revision)
    }
}
