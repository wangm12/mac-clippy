import CryptoKit
import Foundation
import XCTest

import MacClippyCore

final class MacClippyAttachmentRetentionSafetyTests: XCTestCase {
    func testRetentionEvictsLegacySpillWithoutCollectingUnknownSurvivorBlob() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(data: Data(repeating: 0x62, count: 32))
        let database = try MacClippyDatabase(inMemory: true)
        let store = try clipboardStore(database: database, key: key)
        let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
        let blobs = try BlobStore(rootURL: root.appendingPathComponent("blobs"), key: key)
        let firstBlob = try blobs.write(Data("legacy first".utf8), id: "legacy-first")
        let survivingBlob = try blobs.write(Data("legacy survivor".utf8), id: "legacy-survivor")
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = firstDate.addingTimeInterval(1)
        let thirdDate = firstDate.addingTimeInterval(2)
        let first = try store.append(
            .text("legacy first"),
            representations: [spilledRepresentation(firstBlob)],
            now: firstDate
        )
        let second = try store.append(
            .text("legacy survivor"),
            representations: [spilledRepresentation(survivingBlob)],
            now: secondDate
        )
        try replaceWithLegacyEnvelope("legacy first", for: first.id, key: key, in: database)
        try replaceWithLegacyEnvelope("legacy survivor", for: second.id, key: key, in: database)

        let captured = try store.append(.text("new capture"), now: thirdDate)
        try search.upsert(id: first.id, text: "legacy first")
        try search.upsert(id: second.id, text: "legacy survivor")
        try search.upsert(id: captured.id, text: "new capture")

        try RetentionPolicy(maxItems: 2).enforce(store: store, blobs: blobs, search: search)

        XCTAssertTrue(try store.metas(for: [first.id]).isEmpty)
        XCTAssertEqual(Set(try store.metas(for: [second.id, captured.id]).map(\.id)), [second.id, captured.id])
        XCTAssertEqual(Set(try search.indexedRecordIDs()), [second.id, captured.id])
        XCTAssertTrue(try blobs.contains(id: firstBlob))
        XCTAssertTrue(try blobs.contains(id: survivingBlob))
        XCTAssertTrue(try store.pendingDeletions().isEmpty)
    }

    func testRetentionDoesNotTreatWrongKeyAsUnprovenLegacyReference() throws {
        for marker in [0, 1] {
            let database = try MacClippyDatabase(inMemory: true)
            let key = SymmetricKey(data: Data(repeating: 0x13, count: 32))
            let store = try clipboardStore(database: database, key: key)
            let item = try store.append(.text("must survive wrong key"))
            try database.queue.write { connection in
                try connection.execute(
                    sql: "UPDATE clipboard_records SET blob_references_verified = ? WHERE id = ?",
                    arguments: [marker, item.id.rawValue]
                )
            }
            let wrongKeyStore = try clipboardStore(
                database: database,
                key: SymmetricKey(data: Data(repeating: 0x14, count: 32))
            )
            let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
            let blobRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacClippyWrongRetentionKey-\(UUID().uuidString)")
            let blobs = try BlobStore(rootURL: blobRoot, key: key)
            defer { try? FileManager.default.removeItem(at: blobRoot) }

            XCTAssertThrowsError(
                try RetentionPolicy(maxItems: 0).enforce(store: wrongKeyStore, blobs: blobs, search: search),
                "wrong key must fail closed with verified marker \(marker)"
            )
            XCTAssertEqual(try store.metas(for: [item.id]).map(\.id), [item.id])
        }
    }

    func testDeleteRepresentationsRefreshesRosterAndRejectsWrongKey() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let key = SymmetricKey(data: Data(repeating: 0x21, count: 32))
        let store = try clipboardStore(database: database, key: key)
        let item = try store.append(
            .text("has a spilled attachment"),
            representations: [spilledRepresentation("detached-attachment")]
        )

        try store.deleteRepresentations(for: item.id)

        XCTAssertTrue(try store.representations(for: item.id).isEmpty)
        XCTAssertEqual(try verifiedMarker(for: item.id, in: database), 1)
        XCTAssertEqual(try store.unreferencedBlobIDs(["detached-attachment"]), ["detached-attachment"])

        let protected = try store.append(
            .text("must survive wrong key"),
            representations: [spilledRepresentation("protected-attachment")]
        )
        let wrongKeyStore = try clipboardStore(
            database: database,
            key: SymmetricKey(data: Data(repeating: 0x22, count: 32))
        )

        XCTAssertThrowsError(try wrongKeyStore.deleteRepresentations(for: protected.id))
        XCTAssertEqual(try store.representations(for: protected.id).map(\.blobID), ["protected-attachment"])
    }

    private func clipboardStore(database: MacClippyDatabase, key: SymmetricKey) throws -> ClipboardStore {
        try ClipboardStore(
            database: database,
            deviceKey: key,
            deviceID: XCTUnwrap(DeviceID(rawValue: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
        )
    }

    private func verifiedMarker(for id: RecordID, in database: MacClippyDatabase) throws -> Int {
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

    private func replaceWithLegacyEnvelope(
        _ text: String,
        for id: RecordID,
        key: SymmetricKey,
        in database: MacClippyDatabase
    ) throws {
        let encryptedBody = try MacClippyCipher.seal(JSONEncoder().encode(ClipboardRecord.text(text)), with: key)
        try database.queue.write { connection in
            try connection.execute(
                sql: """
                    UPDATE clipboard_records
                    SET envelope = ?, representation_refs_auth = NULL, blob_references_verified = 0
                    WHERE id = ?
                    """,
                arguments: [encryptedBody.combined, id.rawValue]
            )
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyAttachmentRetentionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
