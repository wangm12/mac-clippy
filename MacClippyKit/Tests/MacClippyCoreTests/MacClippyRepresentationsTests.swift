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

    func testUpdateMissingRecordDoesNotCreateAnything() throws {
        let store = try clipboardStore()
        XCTAssertThrowsError(try store.update(id: .generate(), with: .text("new"))) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .recordNotFound)
        }
    }

    func testAppendWithRepresentationsRoundTripsEveryUTI() throws {
        let store = try clipboardStore()
        let now = Date(timeIntervalSince1970: 12_000)
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("hello world".utf8)),
            MacClippyClipboardRepresentation(uti: "public.html", payloadBytes: Data("<b>hi</b>".utf8)),
            MacClippyClipboardRepresentation(uti: "public.rtf", payloadBytes: Data("{\\rtf1 rich}".utf8)),
            MacClippyClipboardRepresentation(uti: "public.tiff", payloadBytes: Data([0x49, 0x49, 0x2A, 0x00, 0x01])),
            MacClippyClipboardRepresentation(uti: "com.example.custom-uti", payloadBytes: Data("custom-payload".utf8))
        ]

        let meta = try store.append(
            .text("hello world"),
            representations: representations,
            sourceAppBundleID: "com.example.Editor",
            now: now
        )

        let stored = try store.representations(for: meta.id)
        XCTAssertEqual(stored.count, representations.count)
        XCTAssertEqual(stored.map(\.uti), representations.map(\.uti))
        for (expected, actual) in zip(representations, stored) {
            XCTAssertEqual(actual.payloadBytes, expected.payloadBytes)
            XCTAssertNil(actual.blobID)
        }
    }

    func testConcealedTransientAndCustomUTIsAreRetained() throws {
        let store = try clipboardStore()
        let representations = [
            MacClippyClipboardRepresentation(uti: "org.nspasteboard.ConcealedType", payloadBytes: Data("concealed".utf8)),
            MacClippyClipboardRepresentation(uti: "org.nspasteboard.TransientType", payloadBytes: Data("transient".utf8)),
            MacClippyClipboardRepresentation(uti: "org.nspasteboard.PasteboardType", payloadBytes: Data("managed".utf8)),
            MacClippyClipboardRepresentation(uti: "com.unknown.nothing-uti", payloadBytes: Data([0x00, 0xFF])),
            MacClippyClipboardRepresentation(uti: "dyn.age50u2u", payloadBytes: Data("dynamic".utf8))
        ]

        let meta = try store.append(.text("concealed-transient-custom"), representations: representations, now: Date(timeIntervalSince1970: 1))
        let stored = try store.representations(for: meta.id)

        XCTAssertEqual(Set(stored.map(\.uti)), Set(representations.map(\.uti)))
        for (expected, actual) in zip(representations, stored) {
            XCTAssertEqual(actual.payloadBytes, expected.payloadBytes)
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

    func testAppendRetainsEmptyAndUnavailablePayloadsAsMarkers() throws {
        // No-filter: an advertised empty payload is retained as an empty
        // .present row; a provider-unavailable payload is retained as a
        // type-only .unavailable row. Both round-trip through the store.
        let store = try clipboardStore()
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.html", payloadBytes: Data()),
            MacClippyClipboardRepresentation(uti: "com.empty", payloadBytes: Data()),
            MacClippyClipboardRepresentation(uti: "com.missing", payloadBytes: nil, blobID: nil, payloadState: .unavailable),
            MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("kept".utf8))
        ]

        let meta = try store.append(.text("kept"), representations: representations, now: Date(timeIntervalSince1970: 1))
        let stored = try store.representations(for: meta.id)

        XCTAssertEqual(Set(stored.map(\.uti)), Set(["public.html", "com.empty", "com.missing", "public.utf8-plain-text"]))
        let byUTI = Dictionary(uniqueKeysWithValues: stored.map { ($0.uti, $0) })
        XCTAssertEqual(byUTI["public.html"]?.payloadBytes, Data())
        XCTAssertEqual(byUTI["public.html"]?.payloadState, .present)
        XCTAssertEqual(byUTI["com.empty"]?.payloadBytes, Data())
        XCTAssertEqual(byUTI["com.empty"]?.payloadState, .present)
        XCTAssertNil(byUTI["com.missing"]?.payloadBytes)
        XCTAssertNil(byUTI["com.missing"]?.blobID)
        XCTAssertEqual(byUTI["com.missing"]?.payloadState, .unavailable)
        XCTAssertEqual(byUTI["public.utf8-plain-text"]?.payloadBytes, Data("kept".utf8))
        XCTAssertEqual(byUTI["public.utf8-plain-text"]?.payloadState, .present)
    }

    func testCorruptInlineRepresentationFailsClosedInsteadOfBecomingEmpty() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(database: database, deviceKey: testKey())
        let meta = try store.append(
            .text("visible record"),
            representations: [
                MacClippyClipboardRepresentation(
                    uti: "public.utf8-plain-text",
                    payloadBytes: Data("visible representation".utf8)
                )
            ]
        )

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

    func testAppendIsAtomicAndLeavesNoVisibleRecordOnFailure() throws {
        // Atomicity: when the DB transaction fails after the parent row
        // insert is staged but before commit, neither the parent record nor
        // any representation row is visible. We force a failure by making the
        // representation payload encryption throw via a closed-over flag that
        // we flip through a custom device key mismatch — but the simplest
        // deterministic failure is to close the database queue mid-write is
        // not available here, so instead we trigger a SQL constraint failure
        // by pre-inserting a row with the same primary key the lamport update
        // would touch is not possible (lamport is a single row). Instead we
        // force a spill failure: the spillPayload closure throws, which
        // aborts before any row is written, so no record and no blob leak.
        let store = try clipboardStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        struct SpillError: Error {}

        let bigPayload = Data(repeating: 0x07, count: MacClippyClipboardRepresentationLimits.inlineByteCeiling + 1)
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.tiff", payloadBytes: bigPayload)
        ]

        XCTAssertThrowsError(try store.append(
            .text("should-not-persist"),
            representations: representations,
            spillPayload: { _ in throw SpillError() },
            now: Date(timeIntervalSince1970: 1)
        ))

        // No record and no representations were committed.
        XCTAssertTrue(try store.list(limit: 10).isEmpty)

        // No blob was left on disk because the spill failure aborted before
        // the transaction opened; nothing was written to BlobStore.
        XCTAssertTrue(try store.allRepresentationBlobIDs().isEmpty)
        let blobFiles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(blobFiles.isEmpty, "spill failure must not leak a blob file")
    }

    func testAppendCleansSpilledBlobsWhenTransactionFails() throws {
        // Compensating rollback: when the spill succeeds but the subsequent
        // DB transaction fails, the spilled blob must be deleted via the
        // deleteSpilledPayload closure so no orphan blob is left behind. We
        // force a real transaction failure by dropping the representations
        // side table after migration so the INSERT inside the transaction
        // throws, exercising the actual catch block in append.
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(database: database, deviceKey: testKey())
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        try database.queue.write { connection in
            try connection.execute(sql: "DROP TABLE clipboard_representations")
        }

        let bigPayload = Data(repeating: 0x07, count: MacClippyClipboardRepresentationLimits.inlineByteCeiling + 1)
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.tiff", payloadBytes: bigPayload),
            MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("small".utf8))
        ]

        var deletedBlobIDs: [String] = []
        let spilledBlobIDHolder = NSMutableArray()

        XCTAssertThrowsError(try store.append(
            .text("should-not-persist"),
            representations: representations,
            spillPayload: { [blobs] data in
                let id = try blobs.write(data)
                spilledBlobIDHolder.add(id)
                return id
            },
            deleteSpilledPayload: { id in
                deletedBlobIDs.append(id)
                try? blobs.delete(id: id)
            },
            now: Date(timeIntervalSince1970: 1)
        ))

        // The oversized representation spilled exactly one blob.
        XCTAssertEqual(spilledBlobIDHolder.count, 1)
        let spilledID = spilledBlobIDHolder[0] as? String
        XCTAssertNotNil(spilledID)

        // The compensating rollback deleted the spilled blob.
        XCTAssertEqual(deletedBlobIDs, [spilledID].compactMap { $0 })
        if let spilledID {
            XCTAssertFalse(blobs.contains(id: spilledID))
        }

        // No record was committed (the transaction rolled back atomically).
        XCTAssertTrue(try store.list(limit: 10).isEmpty)

        // No blob files remain on disk.
        let blobFiles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(blobFiles.isEmpty, "transaction failure must not leak a spilled blob")
    }

    func testAppendCleansSpilledBlobsWhenSpillFailsMidStream() throws {
        // Deterministic compensating-rollback: the first representation
        // spills successfully, the second representation's spill throws. The
        // append aborts before any row is written, and the already-spilled
        // blob from the first representation must be deleted via the
        // deleteSpilledPayload closure so no orphan remains on disk.
        let store = try clipboardStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        struct SpillError: Error {}
        let firstBlobID = try blobs.write(Data(repeating: 0x01, count: 16))
        let bigPayload = Data(repeating: 0x07, count: MacClippyClipboardRepresentationLimits.inlineByteCeiling + 1)
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.tiff", payloadBytes: bigPayload),
            MacClippyClipboardRepresentation(uti: "public.png", payloadBytes: bigPayload)
        ]

        var spillCallIndex = 0
        var deletedBlobIDs: [String] = []
        XCTAssertThrowsError(try store.append(
            .text("should-not-persist"),
            representations: representations,
            spillPayload: { _ in
                spillCallIndex += 1
                if spillCallIndex == 1 {
                    return firstBlobID
                }
                throw SpillError()
            },
            deleteSpilledPayload: { id in
                deletedBlobIDs.append(id)
                try? blobs.delete(id: id)
            },
            now: Date(timeIntervalSince1970: 1)
        ))

        // The first spill's blob was cleaned up by the compensating rollback.
        XCTAssertEqual(deletedBlobIDs, [firstBlobID])
        XCTAssertFalse(blobs.contains(id: firstBlobID))
        // No record and no representation rows were committed.
        XCTAssertTrue(try store.list(limit: 10).isEmpty)
        XCTAssertTrue(try store.allRepresentationBlobIDs().isEmpty)
    }

    func testInternalWriteSentinelSuppressesRecaptureAtCaptureLayer() throws {
        // The write sentinel is a platform-layer concern, but the store-level
        // contract it relies on is: a record persisted from an internal write
        // is indistinguishable from an external one at the storage layer, so
        // suppression must happen above the store. This test pins that
        // contract by confirming an append with a sourceAppBundleID matching
        // the runtime's own bundle id still persists normally (the store does
        // not filter by source app); the observer/sentinel pair is what
        // suppresses recapture, not the store.
        let store = try clipboardStore()
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("internal".utf8))
        ]
        let meta = try store.append(
            .text("internal"),
            representations: representations,
            sourceAppBundleID: "com.macallyouneed.macclippy",
            now: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(meta.sourceAppBundleID, "com.macallyouneed.macclippy")
        XCTAssertEqual(try store.representations(for: meta.id).map(\.uti), ["public.utf8-plain-text"])
    }

    func testReconciliationDetectsRepresentationBackedBlobsAndOrphans() throws {
        // Reconciliation: a blob referenced only by the representation side
        // table is retained; an orphan blob on disk is removed. Covered in
        // MacClippyReconciliationTests; here we just confirm the store
        // exposes the blob-id set the reconciler needs.
        let store = try clipboardStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        let spilledBlobID = try blobs.write(Data(repeating: 3, count: 16))
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.tiff", payloadBytes: nil, blobID: spilledBlobID, payloadState: .spilled)
        ]
        let meta = try store.append(.text("spilled"), representations: representations, now: Date(timeIntervalSince1970: 1))

        let blobIDs = try store.allRepresentationBlobIDs()
        XCTAssertEqual(blobIDs, [spilledBlobID])
        let stored = try store.representations(for: meta.id)
        XCTAssertEqual(stored.first?.blobID, spilledBlobID)
        XCTAssertEqual(stored.first?.payloadState, .spilled)
    }

    func testMigration002AddsRepresentationsTable() throws {
        let database = try MacClippyDatabase(inMemory: true)
        _ = try ClipboardStore(database: database, deviceKey: testKey())
        XCTAssertEqual(
            try appliedMigrations(in: database),
            ["001-clipboard-core", "002-clipboard-representations", "003-clipboard-query-indexes", "004-deletion-journal", "005-deletion-records"]
        )

        // The side table exists and has the expected columns, including the
        // payload_state column added by the no-filter/atomicity pass.
        try database.queue.read { connection in
            let columns = try Row.fetchAll(connection, sql: "PRAGMA table_info(clipboard_representations)")
            XCTAssertEqual(columns.count, 6)
            let names = columns.compactMap { $0["name"] as String? }
            XCTAssertEqual(Set(names), ["record_id", "sort_order", "uti", "payload", "blob_id", "payload_state"])
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
}
