import CryptoKit
import XCTest

import MacClippyCore

final class MacClippyDeletionJournalTests: XCTestCase {
    func testDeletionJournalSurvivesParentRemovalUntilCompleted() throws {
        let store = try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: testKey()
        )
        let blobStore = try BlobStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("MacClippyDeletionJournal-\(UUID().uuidString)"),
            key: testKey()
        )
        let blobID = try blobStore.write(Data([1, 2, 3]))
        let meta = try store.append(
            .text("journal"),
            representations: [
                MacClippyClipboardRepresentation(
                    uti: "public.data",
                    payloadBytes: nil,
                    blobID: blobID
                )
            ]
        )
        defer { try? FileManager.default.removeItem(at: blobStore.encryptedURL(id: "0").deletingLastPathComponent()) }

        let journal = try XCTUnwrap(store.beginDeletion(ids: [meta.id]))
        XCTAssertEqual(journal.recordIDs, [meta.id])
        XCTAssertEqual(journal.blobIDs, [blobID])

        try store.delete(id: meta.id)
        XCTAssertEqual(try store.pendingDeletions(), [journal])

        try store.completeDeletion(operationID: journal.operationID)
        XCTAssertTrue(try store.pendingDeletions().isEmpty)
    }

    func testDeletionJournalDoesNotCreateEntryForMissingRecord() throws {
        let store = try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: testKey()
        )

        XCTAssertNil(try store.beginDeletion(ids: [.generate()]))
        XCTAssertTrue(try store.pendingDeletions().isEmpty)
    }

    func testDeletionJournalRetainsTextRecordWithoutBlobRows() throws {
        let store = try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: testKey()
        )
        let meta = try store.append(.text("journal without blob"))

        let journal = try XCTUnwrap(store.beginDeletion(ids: [meta.id]))
        XCTAssertTrue(journal.blobIDs.isEmpty)

        try store.delete(id: meta.id)
        XCTAssertEqual(try store.pendingDeletions(), [journal])
        XCTAssertEqual(try store.pendingDeletions().first?.recordIDs, [meta.id])

        try store.completeDeletion(operationID: journal.operationID)
        XCTAssertTrue(try store.pendingDeletions().isEmpty)
    }

    func testRetentionKeepsJournalWhenBlobDeletionFails() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(database: database, deviceKey: testKey())
        let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
        let blobRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyDeletionJournalFailure-\(UUID().uuidString)")
        let blobs = try BlobStore(rootURL: blobRoot, key: testKey())
        defer { try? FileManager.default.removeItem(at: blobRoot) }

        let meta = try store.append(
            .text("journal blob failure"),
            representations: [
                MacClippyClipboardRepresentation(
                    uti: "public.data",
                    payloadBytes: nil,
                    blobID: "../invalid-blob-id"
                )
            ]
        )
        try search.upsert(id: meta.id, text: "journal blob failure")

        let policy = RetentionPolicy(maxItems: 0)
        XCTAssertThrowsError(try policy.enforce(store: store, blobs: blobs, search: search))

        XCTAssertTrue(try store.metas(for: [meta.id]).isEmpty)
        XCTAssertTrue(try search.indexedRecordIDs().isEmpty)
        let pending = try store.pendingDeletions()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].recordIDs, [meta.id])
        XCTAssertEqual(pending[0].blobIDs, ["../invalid-blob-id"])
    }

    func testRetentionCompletesJournalAfterSuccessfulTextDeletion() throws {
        let store = try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: testKey()
        )
        let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
        let blobRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyDeletionJournalSuccess-\(UUID().uuidString)")
        let blobs = try BlobStore(
            rootURL: blobRoot,
            key: testKey()
        )
        defer { try? FileManager.default.removeItem(at: blobRoot) }
        let meta = try store.append(.text("journal success"))
        try search.upsert(id: meta.id, text: "journal success")

        try RetentionPolicy(maxItems: 0).enforce(store: store, blobs: blobs, search: search)

        XCTAssertTrue(try store.pendingDeletions().isEmpty)
        XCTAssertTrue(try search.indexedRecordIDs().isEmpty)
    }

    private func testKey() -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 7, count: 32))
    }
}
