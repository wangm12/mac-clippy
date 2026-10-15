import CryptoKit
import Foundation
import XCTest

import GRDB
@testable import MacClippyCore

final class MacClippyAttachmentReferenceIndexTests: XCTestCase {
    func testLegacyMigrationAuthenticatesReferencesAndPersistsVerifiedIndex() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("clipboard.sqlite")
        let key = SymmetricKey(data: Data(repeating: 0x53, count: 32))
        let id = RecordID.generate()
        let blobID = "legacy-migration-blob"
        let record = ClipboardRecord.image(blobID: blobID, width: 2, height: 2)
        let envelope = try MacClippyCipher.seal(JSONEncoder().encode(record), with: key)
        try createLegacyDatabase(at: databaseURL, id: id, envelope: envelope.combined)

        let database = try MacClippyDatabase(url: databaseURL, migrations: ClipboardStore.migrations)
        let store = try clipboardStore(database: database, key: key)
        XCTAssertEqual(try verifiedMarker(for: id, in: database), 0)
        XCTAssertTrue(try store.isBlobReferenced(blobID))
        XCTAssertEqual(store.recordEnvelopeDecryptCount, 1)
        try database.queue.close()

        let reopenedDatabase = try MacClippyDatabase(url: databaseURL, migrations: ClipboardStore.migrations)
        let reopenedStore = try clipboardStore(database: reopenedDatabase, key: key)
        XCTAssertTrue(try reopenedStore.isBlobReferenced(blobID))
        XCTAssertEqual(reopenedStore.recordEnvelopeDecryptCount, 0)
        try reopenedDatabase.queue.close()
    }

    func testSharedRepresentationBlobSurvivesExcludingOnlyOneRecord() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try clipboardStore(database: database)
        let blobID = "shared-attachment"
        let first = try store.append(.text("first"), representations: [spilledRepresentation(blobID)])
        let second = try store.append(.text("second"), representations: [spilledRepresentation(blobID)])
        let decryptCount = store.recordEnvelopeDecryptCount

        XCTAssertTrue(try store.isBlobReferenced(blobID))
        XCTAssertTrue(try store.referencedBlobIDs(excluding: [first.id]).contains(blobID))
        XCTAssertTrue(try store.unreferencedBlobIDs([blobID], excluding: [first.id]).isEmpty)
        XCTAssertEqual(
            try store.unreferencedBlobIDs([blobID], excluding: [first.id, second.id]),
            [blobID]
        )
        XCTAssertEqual(store.recordEnvelopeDecryptCount, decryptCount)
    }

    func testEnvelopeMutationInvalidatesTrustedReferenceAndCorruptionFailsClosed() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try clipboardStore(database: database)
        let referencedID = try store.append(.image(blobID: "authenticated-image", width: 2, height: 2))
        XCTAssertTrue(try store.isBlobReferenced("authenticated-image"))

        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET envelope = ? WHERE id = ?",
                arguments: [Data([0x01, 0x02, 0x03]), referencedID.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.unreferencedBlobIDs(["unrelated-orphan"]))
        let verified: Int? = try database.queue.read { connection in
            try Int.fetchOne(
                connection,
                sql: "SELECT blob_references_verified FROM clipboard_records WHERE id = ?",
                arguments: [referencedID.id.rawValue]
            )
        }
        XCTAssertEqual(verified, 0)
    }

    func testCorruptInlineRepresentationCannotBeSkippedByTrustedIndex() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try clipboardStore(database: database)
        let meta = try store.append(
            .text("with representation"),
            representations: [
                spilledRepresentation("owned-spill"),
                MacClippyClipboardRepresentation(uti: "public.html", payloadBytes: Data("<p>ok</p>".utf8))
            ]
        )

        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_representations SET payload = ? WHERE record_id = ? AND uti = ?",
                arguments: [Data([0x03]), meta.id.rawValue, "public.html"]
            )
        }

        XCTAssertThrowsError(try store.unreferencedBlobIDs(["unrelated-orphan"]))
        XCTAssertThrowsError(try store.isBlobReferenced("owned-spill"))
    }

    func testUnsafeSpilledBlobMetadataFailsClosedDuringBackfill() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try clipboardStore(database: database)
        let meta = try store.append(
            .text("unsafe spill metadata"),
            representations: [spilledRepresentation("owned-spill")]
        )
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_representations SET blob_id = ? WHERE record_id = ?",
                arguments: ["../outside-store", meta.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.unreferencedBlobIDs(["unrelated-orphan"]))
    }

    func testLegacyBackfillIsCancellableInAuthenticatedPagesAndThenIndexed() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try clipboardStore(database: database)
        for index in 0 ..< 130 {
            _ = try store.append(.image(blobID: "legacy-\(index)", width: 2, height: 2))
        }
        try database.queue.write { connection in
            try connection.execute(literal: "UPDATE clipboard_records SET blob_references_verified = 0")
        }

        assertBackfillStopsAtPageBoundary(store)
        XCTAssertEqual(try verifiedRecordCount(in: database), 64)
        try assertBackfillIsCompleteAndCached(store)
    }

    private func assertBackfillStopsAtPageBoundary(_ store: ClipboardStore) {
        var checks = 0
        XCTAssertThrowsError(
            try store.referencedBlobIDs(shouldContinue: {
                checks += 1
                return checks <= 70
            })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func verifiedRecordCount(in database: MacClippyDatabase) throws -> Int {
        try database.queue.read { connection in
            try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM clipboard_records WHERE blob_references_verified = 1"
            ) ?? 0
        }
    }

    private func assertBackfillIsCompleteAndCached(_ store: ClipboardStore) throws {
        let legacyReferences = try store.referencedBlobIDs()
        XCTAssertEqual(legacyReferences.count, 130)
        let decryptCount = store.recordEnvelopeDecryptCount
        XCTAssertEqual(try store.referencedBlobIDs().count, 130)
        XCTAssertEqual(store.recordEnvelopeDecryptCount, decryptCount)
    }

    private func clipboardStore(database: MacClippyDatabase) throws -> ClipboardStore {
        try ClipboardStore(
            database: database,
            deviceKey: SymmetricKey(data: Data(repeating: 0x39, count: 32)),
            deviceID: XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
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

    private func createLegacyDatabase(at url: URL, id: RecordID, envelope: Data) throws {
        let database = try MacClippyDatabase(
            url: url,
            migrations: Array(ClipboardStore.migrations.prefix { $0.identifier != "012-pasteboard-item-identity" })
        )
        try database.queue.write { connection in
            try connection.execute(
                sql: """
                    INSERT INTO clipboard_records (
                        id, created, modified, device_id, lamport, kind, content_kind, preview, envelope
                    ) VALUES (?, 1, 1, ?, 1, ?, ?, 'legacy image', ?)
                    """,
                arguments: [
                    id.rawValue,
                    "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
                    RecordKind.clipboardItem.rawValue,
                    MacClippyContentKind.image.rawValue,
                    envelope
                ]
            )
        }
        try database.queue.close()
    }

    private func spilledRepresentation(_ blobID: String) -> MacClippyClipboardRepresentation {
        MacClippyClipboardRepresentation(
            uti: "com.example.spilled-\(blobID)",
            payloadBytes: nil,
            blobID: blobID,
            payloadState: .spilled
        )
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyAttachmentIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}
