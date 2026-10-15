import CryptoKit
import Foundation
import XCTest

import GRDB
import MacClippyCore

final class MacClippyRepresentationsTests: XCTestCase {
    func testUpdateChangesPrimaryPayloadAndPreservesOtherRepresentations() throws {
        let store = try clipboardStore()
        let originalRepresentations = [
            MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("before".utf8)),
            MacClippyClipboardRepresentation(uti: "public.html", payloadBytes: Data("<b>before</b>".utf8)),
            MacClippyClipboardRepresentation(uti: "com.example.custom", payloadBytes: Data("keep me".utf8))
        ]
        let original = try store.append(.text("before"), representations: originalRepresentations, now: Date(timeIntervalSince1970: 10))

        let updated = try store.update(id: original.id, with: .text("after"), now: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(try store.body(for: original.id), .text("after"))
        XCTAssertEqual(updated.preview, "after")
        XCTAssertEqual(updated.modified, Date(timeIntervalSince1970: 20))
        let representations = try store.representations(for: original.id)
        XCTAssertEqual(representations.first(where: { $0.uti == "public.utf8-plain-text" })?.payloadBytes, Data("after".utf8))
        XCTAssertEqual(representations.first(where: { $0.uti == "public.html" })?.payloadBytes, Data("<b>before</b>".utf8))
        XCTAssertEqual(representations.first(where: { $0.uti == "com.example.custom" })?.payloadBytes, Data("keep me".utf8))
    }

    func testReplaceRepresentationsRestoresSpilledPrimaryBlobReference() throws {
        let store = try clipboardStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let payload = Data(repeating: 0x07, count: MacClippyClipboardRepresentationLimits.inlineByteCeiling + 1)
        let blobID = try blobs.write(payload)
        let meta = try store.append(
            .text("before"),
            representations: [
                MacClippyClipboardRepresentation(
                    uti: "public.utf8-plain-text",
                    payloadBytes: nil,
                    blobID: blobID,
                    payloadState: .spilled
                )
            ]
        )
        let snapshot = try store.representations(for: meta.id)

        _ = try store.update(id: meta.id, with: .text("after"))
        try store.replaceRepresentations(for: meta.id, with: snapshot)

        let restored = try store.representations(for: meta.id)
        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(try blobs.read(id: blobID), payload)
    }

    func testUpdateMissingRecordDoesNotCreateAnything() throws {
        let store = try clipboardStore()
        XCTAssertThrowsError(try store.update(id: .generate(), with: .text("new"))) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .recordNotFound)
        }
    }

    func testLegacyAppendWithoutRepresentationsStillWorks() throws {
        let store = try clipboardStore()
        let meta = try store.append(.text("legacy"), now: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(try store.body(for: meta.id), .text("legacy"))
        // Legacy records have no representations; the read returns empty
        // instead of throwing so callers can always treat missing as empty.
        XCTAssertTrue(try store.representations(for: meta.id).isEmpty)
    }

    func testRepeatedUTIIsPreservedAcrossNativePasteboardItems() throws {
        let store = try clipboardStore()
        let representations = [
            MacClippyClipboardRepresentation(
                itemIndex: 0,
                uti: "public.utf8-plain-text",
                payloadBytes: Data("first item".utf8)
            ),
            MacClippyClipboardRepresentation(
                itemIndex: 1,
                uti: "public.utf8-plain-text",
                payloadBytes: Data("second item".utf8)
            ),
            MacClippyClipboardRepresentation(
                itemIndex: 1,
                uti: "com.example.payload",
                payloadBytes: Data("second custom".utf8)
            )
        ]

        let meta = try store.append(.text("first item"), representations: representations)

        XCTAssertEqual(try store.representations(for: meta.id), representations)
        XCTAssertEqual(try store.playbackSnapshot(for: meta.id).representations.map(\.itemIndex), [0, 1, 1])
    }

    func testPrimaryPayloadUpdateOnlyRewritesTheSelectedNativeItem() throws {
        let store = try clipboardStore()
        let meta = try store.append(
            .text("selected"),
            representations: [
                MacClippyClipboardRepresentation(
                    itemIndex: 0,
                    uti: "public.utf8-plain-text",
                    payloadBytes: Data("selected".utf8)
                ),
                MacClippyClipboardRepresentation(
                    itemIndex: 1,
                    uti: "public.utf8-plain-text",
                    payloadBytes: Data("other item".utf8)
                )
            ]
        )

        _ = try store.update(id: meta.id, with: .text("edited"))

        let representations = try store.representations(for: meta.id)
        XCTAssertEqual(representations.map(\.itemIndex), [0, 1])
        XCTAssertEqual(representations.map(\.payloadBytes), [Data("edited".utf8), Data("other item".utf8)])
    }

    func testRepresentationCodableDefaultsLegacyItemIndexToZero() throws {
        let json = """
            {"uti":"public.utf8-plain-text","payloadBytes":"aGVsbG8=","blobID":null,"payloadState":"present"}
            """
        let decoded = try JSONDecoder().decode(MacClippyClipboardRepresentation.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.itemIndex, 0)
        XCTAssertEqual(decoded.payloadBytes, Data("hello".utf8))
    }

    func testItemIdentityMigrationKeepsLegacyRowsAtIndexZero() throws {
        let root = temporaryDirectoryURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("legacy.sqlite")
        let key = testKey()
        let legacyDatabase = try MacClippyDatabase(
            url: databaseURL,
            migrations: Array(ClipboardStore.migrations.prefix { $0.identifier != "012-pasteboard-item-identity" })
        )
        defer { try? legacyDatabase.queue.close() }
        let id = RecordID.generate()
        let deviceID = try XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        let recordEnvelope = try MacClippyCipher.seal(
            JSONEncoder().encode(ClipboardRecord.text("legacy body")),
            with: key
        ).combined
        let representationEnvelope = try MacClippyCipher.seal(Data("legacy bytes".utf8), with: key).combined
        try legacyDatabase.queue.write { connection in
            try connection.execute(
                sql: """
                    INSERT INTO clipboard_records (
                        id, created, modified, device_id, lamport, kind, content_kind, preview, envelope
                    ) VALUES (?, 1, 1, ?, 1, 'clipboardItem', 'text', 'legacy body', ?)
                    """,
                arguments: [id.rawValue, deviceID.rawValue, recordEnvelope]
            )
            try connection.execute(
                sql: """
                    INSERT INTO clipboard_representations (
                        record_id, sort_order, uti, payload, blob_id, payload_state
                    ) VALUES (?, 0, 'public.utf8-plain-text', ?, NULL, 'present')
                    """,
                arguments: [id.rawValue, representationEnvelope]
            )
        }

        let migratedStore = try ClipboardStore(database: legacyDatabase, deviceKey: key, deviceID: deviceID)
        let snapshot = try migratedStore.playbackSnapshot(for: id)

        XCTAssertEqual(snapshot.record, .text("legacy body"))
        XCTAssertEqual(snapshot.representations.map(\.itemIndex), [0])
        XCTAssertEqual(snapshot.representations.first?.payloadBytes, Data("legacy bytes".utf8))
    }

    func testOversizedPayloadSpillsToBlobStoreAndRoundTrips() throws {
        let store = try clipboardStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        let bigPayload = Data(repeating: 0x07, count: MacClippyClipboardRepresentationLimits.inlineByteCeiling + 1)
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.tiff", payloadBytes: bigPayload),
            MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("small".utf8))
        ]

        let meta = try store.append(
            .image(blobID: try blobs.write(Data([0x01])), width: 1, height: 1),
            representations: representations,
            spillPayload: { data in
                try blobs.write(data)
            },
            now: Date(timeIntervalSince1970: 1)
        )

        let stored = try store.representations(for: meta.id)
        XCTAssertEqual(stored.count, 2)
        let big = stored.first { $0.uti == "public.tiff" }
        let small = stored.first { $0.uti == "public.utf8-plain-text" }
        XCTAssertNotNil(big?.blobID)
        XCTAssertNil(big?.payloadBytes)
        XCTAssertNil(small?.blobID)
        XCTAssertEqual(small?.payloadBytes, Data("small".utf8))

        // The spilled blob is tracked by allRepresentationBlobIDs so
        // reconciliation can find it and the runtime can read it back.
        let blobIDs = try store.allRepresentationBlobIDs()
        XCTAssertTrue(blobIDs.contains(big!.blobID!))
        XCTAssertTrue(try store.blobIDs(for: meta.id).contains(big!.blobID!))
        XCTAssertEqual(try blobs.read(id: big!.blobID!), bigPayload)
    }

    func testDeleteRemovesRepresentationsViaCascade() throws {
        let store = try clipboardStore()
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("doomed".utf8)),
            MacClippyClipboardRepresentation(uti: "public.html", payloadBytes: Data("<b>doomed</b>".utf8))
        ]
        let meta = try store.append(.text("doomed"), representations: representations, now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(try store.representations(for: meta.id).count, 2)

        try store.delete(id: meta.id)

        XCTAssertTrue(try store.representations(for: meta.id).isEmpty)
        XCTAssertThrowsError(try store.body(for: meta.id))
    }

    func testMigration002AddsRepresentationsTable() throws {
        let database = try MacClippyDatabase(inMemory: true)
        _ = try ClipboardStore(database: database, deviceKey: testKey())
        XCTAssertEqual(
            try appliedMigrations(in: database),
            [
                "001-clipboard-core", "002-clipboard-representations", "003-clipboard-query-indexes",
                "004-deletion-journal", "005-deletion-records", "006-capture-content-hash",
                "007-structured-search-indexes", "008-search-and-storage-metadata",
                "009-verified-attachment-references", "010-authenticated-representation-roster",
                "011-content-kind-reference-invalidation", "012-pasteboard-item-identity",
                "013-clipboard-records-revision-and-scope-index"
            ]
        )

        // The side table exists and has the expected columns, including the
        // payload_state column added by the no-filter/atomicity pass.
        try database.queue.read { connection in
            let columns = try Row.fetchAll(connection, sql: "PRAGMA table_info(clipboard_representations)")
            XCTAssertEqual(columns.count, 7)
            let names = columns.compactMap { $0["name"] as String? }
            XCTAssertEqual(
                Set(names),
                ["record_id", "item_index", "sort_order", "uti", "payload", "blob_id", "payload_state"]
            )
        }
    }

    private func clipboardStore() throws -> ClipboardStore {
        try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: testKey(),
            deviceID: try XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
    }

    private func appliedMigrations(in database: MacClippyDatabase) throws -> [String] {
        try database.queue.read { connection in
            try String.fetchAll(connection, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    private func testKey() -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 9, count: 32))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyRepresentationsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func temporaryDirectoryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyLegacyRepresentationMigration-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
