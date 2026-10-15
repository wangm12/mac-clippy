import CryptoKit
import XCTest

import GRDB
import MacClippyCore

final class MacClippyRepresentationStateTests: XCTestCase {
    func testCorruptInlineRepresentationFailsClosedInsteadOfBecomingEmpty() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try clipboardStore(in: database)
        let meta = try appendVisibleRecord(to: store, text: "visible representation")

        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_representations SET payload = ? WHERE record_id = ?",
                arguments: [Data([0x00, 0x01, 0x02]), meta.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.representations(for: meta.id)) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .invalidStoredRecord)
        }
    }

    func testInvalidRepresentationPayloadStateFailsClosed() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try clipboardStore(in: database)
        let meta = try appendVisibleRecord(to: store, text: "visible")

        try database.queue.write { connection in
            try connection.execute(
                sql: """
                    UPDATE clipboard_representations
                    SET payload_state = ?, payload = NULL, blob_id = NULL WHERE record_id = ?
                    """,
                arguments: ["unknown-state", meta.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.representations(for: meta.id)) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .invalidStoredRecord)
        }
        XCTAssertThrowsError(try store.representationUTIs(for: meta.id)) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .invalidStoredRecord)
        }
        XCTAssertThrowsError(try store.validateRepresentations()) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .invalidStoredRecord)
        }
    }

    func testInvalidRepresentationPayloadCombinationIsDetectedByMaintenanceValidation() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try clipboardStore(in: database)
        let meta = try appendVisibleRecord(to: store, text: "visible")

        try database.queue.write { connection in
            try connection.execute(
                sql: """
                    UPDATE clipboard_representations
                    SET payload_state = 'present', payload = NULL, blob_id = NULL WHERE record_id = ?
                    """,
                arguments: [meta.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.validateRepresentations()) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .invalidStoredRecord)
        }
    }

    func testInvalidRepresentationPayloadStateCombinationFailsOnAppend() throws {
        let store = try clipboardStore(in: MacClippyDatabase(inMemory: true))
        let invalid = MacClippyClipboardRepresentation(
            uti: "public.data",
            payloadBytes: Data("unexpected".utf8),
            blobID: "blob-id",
            payloadState: .spilled
        )

        XCTAssertThrowsError(try store.append(.text("record"), representations: [invalid])) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .invalidStoredRecord)
        }
    }

    private func appendVisibleRecord(to store: ClipboardStore, text: String) throws -> ClipboardItemMeta {
        try store.append(
            .text("visible record"),
            representations: [
                MacClippyClipboardRepresentation(
                    uti: "public.utf8-plain-text",
                    payloadBytes: Data(text.utf8)
                )
            ]
        )
    }

    private func clipboardStore(in database: MacClippyDatabase) throws -> ClipboardStore {
        try ClipboardStore(database: database, deviceKey: SymmetricKey(data: Data(repeating: 9, count: 32)))
    }
}
