import CryptoKit
import Foundation
import XCTest

import GRDB
import MacClippyCore

final class MacClippyRosterAuthenticationTests: XCTestCase {
    func testAuthenticatedRosterRejectsSpillChangedToUnavailable() throws {
        let fixture = try indexedSpillFixture()
        let database = fixture.database
        let store = fixture.store
        let meta = fixture.meta
        try database.queue.write { connection in
            try connection.execute(
                sql: """
                    UPDATE clipboard_representations
                    SET payload_state = 'unavailable', blob_id = NULL WHERE record_id = ?
                    """,
                arguments: [meta.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.unreferencedBlobIDs(["owned-spill"]))
        XCTAssertEqual(try referenceMarker(for: meta.id, in: database), 0)
    }

    func testAuthenticatedRosterRejectsBlobIDRewrite() throws {
        let fixture = try indexedSpillFixture()
        let database = fixture.database
        let store = fixture.store
        let meta = fixture.meta
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_representations SET blob_id = 'rewritten-spill' WHERE record_id = ?",
                arguments: [meta.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.unreferencedBlobIDs(["owned-spill"]))
        XCTAssertEqual(try referenceMarker(for: meta.id, in: database), 0)
    }

    func testAuthenticatedRosterRejectsRepresentationReordering() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try clipboardStore(database: database)
        let meta = try store.append(
            .text("ordered representations"),
            representations: [
                spilledRepresentation("first-spill"),
                spilledRepresentation("second-spill")
            ]
        )
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_representations SET sort_order = 0 WHERE record_id = ? AND uti = ?",
                arguments: [meta.id.rawValue, "com.example.spilled-second-spill"]
            )
        }

        XCTAssertThrowsError(try store.unreferencedBlobIDs(["first-spill"]))
        XCTAssertEqual(try referenceMarker(for: meta.id, in: database), 0)
    }

    func testPlaybackRejectsRepresentationMovedToDifferentNativeItem() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try clipboardStore(database: database)
        let meta = try store.append(
            .text("first"),
            representations: [
                MacClippyClipboardRepresentation(
                    itemIndex: 0,
                    uti: "public.utf8-plain-text",
                    payloadBytes: Data("first".utf8)
                ),
                MacClippyClipboardRepresentation(
                    itemIndex: 1,
                    uti: "public.utf8-plain-text",
                    payloadBytes: Data("second".utf8)
                )
            ]
        )
        try database.queue.write { connection in
            try connection.execute(
                sql: """
                    UPDATE clipboard_representations SET item_index = 2
                    WHERE record_id = ? AND sort_order = 1
                    """,
                arguments: [meta.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.playbackSnapshot(for: meta.id))
        XCTAssertEqual(try referenceMarker(for: meta.id, in: database), 0)
    }

    func testAuthenticatedRosterRejectsDeletedRepresentationRow() throws {
        let fixture = try indexedSpillFixture()
        let database = fixture.database
        let store = fixture.store
        let meta = fixture.meta
        try database.queue.write { connection in
            try connection.execute(
                sql: "DELETE FROM clipboard_representations WHERE record_id = ?",
                arguments: [meta.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.unreferencedBlobIDs(["owned-spill"]))
        XCTAssertEqual(try referenceMarker(for: meta.id, in: database), 0)
    }

    func testAuthenticatedRosterRejectsInjectedRepresentationRow() throws {
        let fixture = try indexedSpillFixture()
        let database = fixture.database
        let store = fixture.store
        let meta = fixture.meta
        try database.queue.write { connection in
            try connection.execute(
                sql: """
                    INSERT INTO clipboard_representations (
                        record_id, item_index, sort_order, uti, payload, blob_id, payload_state
                    ) VALUES (?, 0, 1, 'public.extra', NULL, NULL, 'unavailable')
                    """,
                arguments: [meta.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.unreferencedBlobIDs(["owned-spill"]))
        XCTAssertEqual(try referenceMarker(for: meta.id, in: database), 0)
    }

    func testCurrentRecordCannotLoseRosterAndDowngradeToLegacy() throws {
        let fixture = try indexedSpillFixture()
        let database = fixture.database
        let store = fixture.store
        let meta = fixture.meta
        try database.queue.write { connection in
            try connection.execute(
                sql: "DELETE FROM clipboard_representations WHERE record_id = ?",
                arguments: [meta.id.rawValue]
            )
            try connection.execute(
                sql: "UPDATE clipboard_records SET representation_refs_auth = NULL WHERE id = ?",
                arguments: [meta.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.unreferencedBlobIDs(["owned-spill"]))
        XCTAssertEqual(try referenceMarker(for: meta.id, in: database), 0)
    }

    func testUpdateCannotDowngradeCurrentBodyWhenRosterIsMissing() throws {
        let fixture = try indexedSpillFixture()
        let database = fixture.database
        let store = fixture.store
        let meta = fixture.meta
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET representation_refs_auth = NULL WHERE id = ?",
                arguments: [meta.id.rawValue]
            )
        }
        let originalEnvelope: Data = try database.queue.read { connection in
            try Data.fetchOne(
                connection,
                sql: "SELECT envelope FROM clipboard_records WHERE id = ?",
                arguments: [meta.id.rawValue]
            ) ?? Data()
        }

        XCTAssertThrowsError(try store.update(id: meta.id, with: .text("replacement")))

        let afterEnvelope: Data = try database.queue.read { connection in
            try Data.fetchOne(
                connection,
                sql: "SELECT envelope FROM clipboard_records WHERE id = ?",
                arguments: [meta.id.rawValue]
            ) ?? Data()
        }
        XCTAssertEqual(afterEnvelope, originalEnvelope)
        XCTAssertEqual(try referenceMarker(for: meta.id, in: database), 0)
    }

    func testInvalidAttachmentVerificationMarkerCannotBeStoredOrTrusted() throws {
        let fixture = try indexedSpillFixture()
        let database = fixture.database
        let store = fixture.store
        let meta = fixture.meta

        XCTAssertThrowsError(try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET blob_references_verified = 2 WHERE id = ?",
                arguments: [meta.id.rawValue]
            )
        })
        XCTAssertTrue(try store.isBlobReferenced("owned-spill"))
        XCTAssertEqual(try referenceMarker(for: meta.id, in: database), 1)
    }

    func testLegacySpilledReferenceWithoutAuthenticatedRosterFailsClosed() throws {
        let fixture = try indexedSpillFixture()
        let database = fixture.database
        let store = fixture.store
        let meta = fixture.meta
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET representation_refs_auth = NULL WHERE id = ?",
                arguments: [meta.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.unreferencedBlobIDs(["unrelated-orphan"]))
        XCTAssertEqual(try referenceMarker(for: meta.id, in: database), 0)
    }

    private struct Fixture {
        let database: MacClippyDatabase
        let store: ClipboardStore
        let meta: ClipboardItemMeta
    }

    private func clipboardStore(database: MacClippyDatabase) throws -> ClipboardStore {
        try ClipboardStore(
            database: database,
            deviceKey: SymmetricKey(data: Data(repeating: 0x39, count: 32)),
            deviceID: XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
    }

    private func indexedSpillFixture() throws -> Fixture {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try clipboardStore(database: database)
        let meta = try store.append(
            .text("authenticated spill"),
            representations: [spilledRepresentation("owned-spill")]
        )
        return Fixture(database: database, store: store, meta: meta)
    }

    private func referenceMarker(for id: RecordID, in database: MacClippyDatabase) throws -> Int {
        try database.queue.read { connection in
            try Int.fetchOne(
                connection,
                sql: "SELECT blob_references_verified FROM clipboard_records WHERE id = ?",
                arguments: [id.rawValue]
            ) ?? -1
        }
    }

    private func spilledRepresentation(_ blobID: String) -> MacClippyClipboardRepresentation {
        MacClippyClipboardRepresentation(
            uti: "com.example.spilled-\(blobID)",
            payloadBytes: nil,
            blobID: blobID,
            payloadState: .spilled
        )
    }
}
