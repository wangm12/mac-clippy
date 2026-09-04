import CryptoKit
import XCTest

@testable import MacClippyCore

final class MacClippyCaptureDedupStoreTests: XCTestCase {
    func testAppendOrReuseBumpsFrequencyWithoutInsertingASecondRow() throws {
        let store = try clipboardStore()
        let hash = MacClippyCaptureDedupPolicy.contentHash(primary: .text("same"), representations: [])
        let firstNow = Date(timeIntervalSince1970: 1_000)
        let first = try store.appendOrReuse(
            .text("same"),
            representations: [],
            contentHash: hash,
            now: firstNow
        )

        XCTAssertFalse(first.reusedExisting)
        XCTAssertEqual(first.meta.frequency, 0)
        XCTAssertNil(first.meta.lastAccessed)
        XCTAssertEqual(try store.list(limit: 10).map(\.id), [first.meta.id])

        let reuseNow = Date(timeIntervalSince1970: 2_000)
        let reused = try store.appendOrReuse(
            .text("same"),
            representations: [],
            contentHash: hash,
            now: reuseNow
        )

        XCTAssertTrue(reused.reusedExisting)
        XCTAssertEqual(reused.meta.id, first.meta.id)
        XCTAssertEqual(reused.meta.frequency, 1)
        XCTAssertEqual(reused.meta.lastAccessed, reuseNow)
        XCTAssertEqual(reused.meta.modified, reuseNow)
        XCTAssertEqual(try store.list(limit: 10).count, 1)
        XCTAssertEqual(try store.body(for: first.meta.id), .text("same"))
    }

    func testAppendOrReuseInsertsWhenTheHashIsDifferent() throws {
        let store = try clipboardStore()
        let first = try store.appendOrReuse(
            .text("alpha"),
            representations: [],
            contentHash: MacClippyCaptureDedupPolicy.contentHash(primary: .text("alpha"), representations: []),
            now: Date(timeIntervalSince1970: 1)
        )
        let second = try store.appendOrReuse(
            .text("beta"),
            representations: [],
            contentHash: MacClippyCaptureDedupPolicy.contentHash(primary: .text("beta"), representations: []),
            now: Date(timeIntervalSince1970: 2)
        )

        XCTAssertFalse(first.reusedExisting)
        XCTAssertFalse(second.reusedExisting)
        XCTAssertNotEqual(first.meta.id, second.meta.id)
        XCTAssertEqual(try store.list(limit: 10).count, 2)
    }

    func testUpdateClearsContentHashSoOriginalCopyIsNotBoundToTheEditedRow() throws {
        let store = try clipboardStore()
        let originalHash = MacClippyCaptureDedupPolicy.contentHash(
            primary: .text("same"),
            representations: []
        )
        let first = try store.appendOrReuse(
            .text("same"),
            representations: [],
            contentHash: originalHash,
            now: Date(timeIntervalSince1970: 1)
        )

        _ = try store.update(id: first.meta.id, with: .text("edited"), now: Date(timeIntervalSince1970: 2))

        let recopy = try store.appendOrReuse(
            .text("same"),
            representations: [],
            contentHash: originalHash,
            now: Date(timeIntervalSince1970: 3)
        )

        XCTAssertFalse(recopy.reusedExisting)
        XCTAssertNotEqual(recopy.meta.id, first.meta.id)
        XCTAssertEqual(try store.body(for: first.meta.id), .text("edited"))
        XCTAssertEqual(try store.body(for: recopy.meta.id), .text("same"))
        XCTAssertEqual(try store.list(limit: 10).count, 2)
    }

    func testImageUpdateReplacesRepresentationsAndRehashes() throws {
        let store = try clipboardStore()
        let originalPNG = Data(repeating: 0x89, count: 64)
        let jpeg = Data(repeating: 0xFF, count: 32)
        let originalHash = MacClippyCaptureDedupPolicy.contentHash(
            primary: .image(originalPNG, width: 4_000, height: 3_000),
            representations: [
                MacClippyCaptureDedupRepresentation(
                    uti: "public.png",
                    payloadState: "present",
                    payloadBytes: originalPNG
                )
            ]
        )
        let first = try store.appendOrReuse(
            .image(blobID: "old-blob", width: 4_000, height: 3_000),
            representations: [
                MacClippyClipboardRepresentation(uti: "public.png", payloadBytes: originalPNG)
            ],
            contentHash: originalHash,
            now: Date(timeIntervalSince1970: 1)
        )
        let jpegHash = MacClippyCaptureDedupPolicy.contentHash(
            primary: .image(jpeg, width: 2_048, height: 1_536),
            representations: [
                MacClippyCaptureDedupRepresentation(
                    uti: "public.jpeg",
                    payloadState: "present",
                    payloadBytes: jpeg
                )
            ]
        )

        _ = try store.update(
            id: first.meta.id,
            with: .image(blobID: "new-blob", width: 2_048, height: 1_536),
            representations: [
                MacClippyClipboardRepresentation(uti: "public.jpeg", payloadBytes: jpeg)
            ],
            contentHash: jpegHash,
            now: Date(timeIntervalSince1970: 2)
        )

        XCTAssertEqual(try store.body(for: first.meta.id), .image(blobID: "new-blob", width: 2_048, height: 1_536))
        XCTAssertEqual(try store.representations(for: first.meta.id).map(\.uti), ["public.jpeg"])
        XCTAssertEqual(try store.representations(for: first.meta.id).first?.payloadBytes, jpeg)

        let recopyOriginal = try store.appendOrReuse(
            .image(blobID: "recopy-blob", width: 4_000, height: 3_000),
            representations: [
                MacClippyClipboardRepresentation(uti: "public.png", payloadBytes: originalPNG)
            ],
            contentHash: originalHash,
            now: Date(timeIntervalSince1970: 3)
        )
        XCTAssertFalse(recopyOriginal.reusedExisting)
        XCTAssertNotEqual(recopyOriginal.meta.id, first.meta.id)
    }

    func testImageBlobIDsAreListedWithoutOpeningEnvelopes() throws {
        let store = try clipboardStore()
        let first = try store.append(
            .image(blobID: "image-blob", width: 8, height: 8),
            representations: [
                MacClippyClipboardRepresentation(
                    uti: "public.png",
                    payloadBytes: nil,
                    blobID: "rep-blob",
                    payloadState: .spilled
                )
            ]
        )
        let decrypts = store.recordEnvelopeDecryptCount

        XCTAssertEqual(try store.imageBlobIDs(), ["image-blob", "rep-blob"])
        XCTAssertEqual(store.recordEnvelopeDecryptCount, decrypts)
        XCTAssertEqual(first.contentKind, .image)
    }

    func testImageBlobIDsBackfillAMissingPrimaryBlobColumn() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(
            database: database,
            deviceKey: SymmetricKey(data: Data(repeating: 9, count: 32)),
            deviceID: XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
        let meta = try store.append(.image(blobID: "legacy-image", width: 8, height: 8))
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET primary_blob_id = NULL WHERE id = ?",
                arguments: [meta.id.rawValue]
            )
        }
        XCTAssertEqual(try store.imageBlobIDs(), ["legacy-image"])
        let stored: String? = try database.queue.read { connection in
            try String.fetchOne(
                connection,
                sql: "SELECT primary_blob_id FROM clipboard_records WHERE id = ?",
                arguments: [meta.id.rawValue]
            )
        }
        XCTAssertEqual(stored, "legacy-image")
        let decrypts = store.recordEnvelopeDecryptCount
        XCTAssertEqual(try store.imageBlobIDs(), ["legacy-image"])
        XCTAssertEqual(store.recordEnvelopeDecryptCount, decrypts)
    }

    func testAppendOrReuseInsertsWhenExistingEnvelopeCannotBeOpened() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(
            database: database,
            deviceKey: SymmetricKey(data: Data(repeating: 9, count: 32)),
            deviceID: XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
        let hash = MacClippyCaptureDedupPolicy.contentHash(primary: .text("same"), representations: [])
        let first = try store.appendOrReuse(
            .text("same"),
            representations: [],
            contentHash: hash,
            now: Date(timeIntervalSince1970: 1)
        )

        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET envelope = ? WHERE id = ?",
                arguments: [Data([0x01, 0x02, 0x03]), first.meta.id.rawValue]
            )
        }

        let recopy = try store.appendOrReuse(
            .text("same"),
            representations: [],
            contentHash: hash,
            now: Date(timeIntervalSince1970: 2)
        )

        XCTAssertFalse(recopy.reusedExisting)
        XCTAssertNotEqual(recopy.meta.id, first.meta.id)
        XCTAssertEqual(try store.list(limit: 10).count, 2)
        XCTAssertEqual(try store.body(for: recopy.meta.id), .text("same"))
    }

    private func clipboardStore() throws -> ClipboardStore {
        try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: SymmetricKey(data: Data(repeating: 9, count: 32)),
            deviceID: XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
    }
}
