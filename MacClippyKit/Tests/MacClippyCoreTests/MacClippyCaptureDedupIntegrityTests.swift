import CryptoKit
import Foundation
import XCTest

import GRDB
@testable import MacClippyCore

final class MacClippyCaptureDedupIntegrityTests: XCTestCase {
    func testAppendOrReuseFailsClosedOnEqualLengthCorruptedEnvelope() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try clipboardStore(database: database)
        let hash = MacClippyCaptureDedupPolicy.contentHash(primary: .text("same"), representations: [])
        let first = try store.appendOrReuse(
            .text("same"),
            representations: [],
            contentHash: hash,
            now: Date(timeIntervalSince1970: 1)
        )

        let originalEnvelope = try XCTUnwrap(try database.queue.read { connection in
            try Data.fetchOne(
                connection,
                sql: "SELECT envelope FROM clipboard_records WHERE id = ?",
                arguments: [first.meta.id.rawValue]
            )
        })
        let corruptedEnvelope = Data(repeating: 0x01, count: originalEnvelope.count)
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET envelope = ? WHERE id = ?",
                arguments: [corruptedEnvelope, first.meta.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.appendOrReuse(
            .text("same"),
            representations: [],
            contentHash: hash,
            now: Date(timeIntervalSince1970: 2)
        ))
        XCTAssertEqual(try store.list(limit: 10).map(\.id), [first.meta.id])
        let retainedHash: String? = try database.queue.read { connection in
            try String.fetchOne(
                connection,
                sql: "SELECT content_hash FROM clipboard_records WHERE id = ?",
                arguments: [first.meta.id.rawValue]
            )
        }
        XCTAssertEqual(retainedHash, hash)
        let retainedEnvelope: Data = try database.queue.read { connection in
            try Data.fetchOne(
                connection,
                sql: "SELECT envelope FROM clipboard_records WHERE id = ?",
                arguments: [first.meta.id.rawValue]
            ) ?? Data()
        }
        XCTAssertEqual(retainedEnvelope, corruptedEnvelope)
    }

    func testMissingPrimaryImageBlobInvalidatesOnlyTheDuplicateHash() throws {
        let store = try clipboardStore()
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let imageData = Data(repeating: 0x57, count: 96)
        try blobs.write(imageData, id: "old-primary")
        try blobs.write(imageData, id: "new-primary")
        let hash = MacClippyCaptureDedupPolicy.contentHash(
            primary: .image(imageData, width: 12, height: 8),
            representations: []
        )
        let original = try store.appendOrReuse(
            .image(blobID: "old-primary", width: 12, height: 8),
            representations: [],
            contentHash: hash,
            readBlob: { try blobs.read(id: $0) }
        )
        try blobs.delete(id: "old-primary")

        let recopy = try store.appendOrReuse(
            .image(blobID: "new-primary", width: 12, height: 8),
            representations: [],
            contentHash: hash,
            readBlob: { try blobs.read(id: $0) }
        )

        XCTAssertFalse(recopy.reusedExisting)
        XCTAssertNotEqual(recopy.meta.id, original.meta.id)
        XCTAssertEqual(try store.list(limit: 10).count, 2)
        XCTAssertEqual(
            try store.body(for: original.meta.id),
            .image(blobID: "old-primary", width: 12, height: 8)
        )
    }

    func testMissingSpilledRepresentationAllowsFreshCopyWithoutReusingCandidate() throws {
        let store = try clipboardStore()
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let representationData = Data("custom representation".utf8)
        try blobs.write(representationData, id: "old-spill")
        let hash = MacClippyCaptureDedupPolicy.contentHash(
            primary: .text("same body"),
            representations: [
                MacClippyCaptureDedupRepresentation(
                    uti: "com.example.custom",
                    payloadState: MacClippyClipboardRepresentationPayloadState.present.rawValue,
                    payloadBytes: representationData
                )
            ]
        )
        let original = try store.appendOrReuse(
            .text("same body"),
            representations: [
                MacClippyClipboardRepresentation(
                    uti: "com.example.custom",
                    payloadBytes: nil,
                    blobID: "old-spill",
                    payloadState: .spilled
                )
            ],
            contentHash: hash,
            readBlob: { try blobs.read(id: $0) }
        )
        try blobs.delete(id: "old-spill")

        let recopy = try store.appendOrReuse(
            .text("same body"),
            representations: [
                MacClippyClipboardRepresentation(
                    uti: "com.example.custom",
                    payloadBytes: representationData
                )
            ],
            contentHash: hash,
            readBlob: { try blobs.read(id: $0) }
        )

        XCTAssertFalse(recopy.reusedExisting)
        XCTAssertNotEqual(recopy.meta.id, original.meta.id)
        XCTAssertEqual(try store.list(limit: 10).count, 2)
        XCTAssertEqual(try store.body(for: original.meta.id), .text("same body"))
    }

    private func clipboardStore() throws -> ClipboardStore {
        try clipboardStore(database: MacClippyDatabase(inMemory: true))
    }

    private func clipboardStore(database: MacClippyDatabase) throws -> ClipboardStore {
        try ClipboardStore(
            database: database,
            deviceKey: testKey(),
            deviceID: XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
    }

    private func testKey() -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 9, count: 32))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyCaptureDedupIntegrityTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
