import Foundation
import MacClippyCore
import XCTest

extension MacClippyCoreTests {
    func testTotalCapDeletesStableHistoryDespiteCandidateAuthentication() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let blobID = try blobs.write(Data(repeating: 7, count: 256))
        _ = try store.append(.text("ordinary retained text"))
        let image = try store.append(.image(blobID: blobID, width: 1, height: 1))
        try search.upsert(id: image.id, text: "ordinary retained image")

        try RetentionPolicy(maxTotalBytes: 0).enforceTotalCap(
            store: store, blobs: blobs, search: search, protectedIDs: []
        )

        XCTAssertTrue(try store.list(limit: 10).isEmpty)
        XCTAssertTrue(try search.search(terms: ["ordinary"], limit: 10).isEmpty)
        XCTAssertFalse(try blobs.contains(id: blobID))
    }

    func testTotalCapRecountsRealPrimaryBlobBackfillBeforeDeleting() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(database: database, deviceKey: testKey())
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let blobID = try blobs.write(Data(repeating: 7, count: 256))
        let image = try store.append(.image(blobID: blobID, width: 1, height: 1))
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET primary_blob_id = NULL WHERE id = ?",
                arguments: [image.id.rawValue]
            )
        }
        var commits = 0

        try RetentionPolicy(maxTotalBytes: 0).enforceTotalCap(
            store: store, blobs: blobs, search: search, protectedIDs: [],
            withCommitFence: { operation in commits += 1; try operation() }
        )

        XCTAssertGreaterThan(commits, 1)
        XCTAssertLessThanOrEqual(commits, 4)
        XCTAssertTrue(try store.list(limit: 10).isEmpty)
        XCTAssertFalse(try blobs.contains(id: blobID))
    }

    func testTotalCapUsesActualBlobReclamationWhenNewOwnerAppearsAtCommit() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let sharedBlob = try blobs.write(Data(repeating: 7, count: 4_096))
        let otherBlob = try blobs.write(Data(repeating: 8, count: 4_096))
        let oldest = try store.append(
            .image(blobID: sharedBlob, width: 1, height: 1), now: Date(timeIntervalSince1970: 1)
        )
        let other = try store.append(
            .image(blobID: otherBlob, width: 1, height: 1), now: Date(timeIntervalSince1970: 2)
        )
        let cap = try store.storageFootprint(for: other.id).inlineBytes + blobs.byteSizeChecked(id: otherBlob)
        var newOwner: ClipboardItemMeta?

        try RetentionPolicy(maxTotalBytes: cap).enforce(
            store: store, blobs: blobs, search: search,
            withCommitFence: { operation in
                if newOwner == nil {
                    newOwner = try store.append(
                        .image(blobID: sharedBlob, width: 1, height: 1), now: Date(timeIntervalSince1970: 3)
                    )
                }
                try operation()
            }
        )

        let survivor = try XCTUnwrap(newOwner)
        XCTAssertThrowsError(try store.body(for: oldest.id))
        XCTAssertThrowsError(try store.body(for: other.id))
        XCTAssertNoThrow(try store.body(for: survivor.id))
        XCTAssertTrue(try blobs.contains(id: sharedBlob))
        XCTAssertFalse(try blobs.contains(id: otherBlob))
        let actual = try store.storageFootprint(for: survivor.id).inlineBytes + blobs.byteSizeChecked(id: sharedBlob)
        XCTAssertLessThanOrEqual(actual, cap)
    }

    func testTotalCapRecountsInlinePayloadInsertedDuringDeletion() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        _ = try store.append(.text("same-size payload"), now: Date(timeIntervalSince1970: 1))
        let other = try store.append(.text("same-size payload"), now: Date(timeIntervalSince1970: 2))
        let cap = try store.storageFootprint(for: other.id).inlineBytes
        var inserted = false

        try RetentionPolicy(maxTotalBytes: cap).enforce(
            store: store, blobs: blobs, search: search,
            withCommitFence: { operation in
                if !inserted {
                    inserted = true
                    _ = try store.append(
                        .text(String(repeating: "x", count: 20_000)), now: Date(timeIntervalSince1970: 3)
                    )
                }
                try operation()
            }
        )

        let actual = try store.list(limit: 10).reduce(0) { total, meta in
            total + (try store.storageFootprint(for: meta.id).inlineBytes)
        }
        XCTAssertLessThanOrEqual(actual, cap)
    }

    func testTotalCapKeepsNewerHistoryWhenLastUnprotectedSharedOwnerIsRemoved() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let blobID = try blobs.write(Data(repeating: 7, count: 8_192))
        let oldest = try store.append(.image(blobID: blobID, width: 1, height: 1), now: Date(timeIntervalSince1970: 1))
        let pinned = try store.append(.image(blobID: blobID, width: 1, height: 1), now: Date(timeIntervalSince1970: 2))
        let newer = try store.append(.text("keep this recent payload"), now: Date(timeIntervalSince1970: 3))
        let cap = try store.storageFootprint(for: newer.id).inlineBytes

        try RetentionPolicy(maxTotalBytes: cap).enforceTotalCap(
            store: store, blobs: blobs, search: search, protectedIDs: [pinned.id]
        )

        XCTAssertThrowsError(try store.body(for: oldest.id))
        XCTAssertNoThrow(try store.body(for: pinned.id))
        XCTAssertNoThrow(try store.body(for: newer.id))
        XCTAssertTrue(try blobs.contains(id: blobID))
    }

    func testTotalCapRefreshesBudgetWhenNewSharedOwnerBecomesProtectedAtCommit() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let blobID = try blobs.write(Data(repeating: 7, count: 8_192))
        let oldest = try store.append(.image(blobID: blobID, width: 1, height: 1), now: Date(timeIntervalSince1970: 1))
        let newer = try store.append(.text("keep this recent payload"), now: Date(timeIntervalSince1970: 2))
        let cap = try store.storageFootprint(for: newer.id).inlineBytes
        var protectedIDs = Set<RecordID>()
        var pinned: ClipboardItemMeta?

        try RetentionPolicy(maxTotalBytes: cap).enforceTotalCap(
            store: store, blobs: blobs, search: search, protectedIDs: [],
            withCommitFence: { operation in
                if pinned == nil {
                    let owner = try store.append(.image(blobID: blobID, width: 1, height: 1))
                    pinned = owner
                    protectedIDs.insert(owner.id)
                }
                try operation()
            },
            protectedIDsProvider: { protectedIDs }
        )

        XCTAssertThrowsError(try store.body(for: oldest.id))
        XCTAssertNoThrow(try store.body(for: XCTUnwrap(pinned).id))
        XCTAssertNoThrow(try store.body(for: newer.id))
        XCTAssertTrue(try blobs.contains(id: blobID))
    }

    func testTotalCapDoesNotDeletePlannedBatchAfterConcurrentPinMakesBudgetFit() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let oldest = try store.append(.text("keep older payload"), now: Date(timeIntervalSince1970: 1))
        let middle = try store.append(.text("keep middle payload"), now: Date(timeIntervalSince1970: 2))
        let newest = try store.append(.text(String(repeating: "p", count: 8_192)), now: Date(timeIntervalSince1970: 3))
        let cap = try store.storageFootprint(for: oldest.id).inlineBytes
            + store.storageFootprint(for: middle.id).inlineBytes
        var protectedIDs = Set<RecordID>()

        try RetentionPolicy(maxTotalBytes: cap).enforceTotalCap(
            store: store, blobs: blobs, search: search, protectedIDs: [],
            withCommitFence: { operation in
                protectedIDs.insert(newest.id)
                try operation()
            },
            protectedIDsProvider: { protectedIDs }
        )

        XCTAssertNoThrow(try store.body(for: oldest.id))
        XCTAssertNoThrow(try store.body(for: middle.id))
        XCTAssertNoThrow(try store.body(for: newest.id))
    }

    func testTotalCapReplansWhenInlinePayloadShrinksWithoutChangingPreviewOrModified() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let oldest = try store.append(.text(String(repeating: "o", count: 4_096)), now: Date(timeIntervalSince1970: 1))
        let newer = try store.append(.text(String(repeating: "x", count: 8_192)), now: Date(timeIntervalSince1970: 2))
        let cap = try store.storageFootprint(for: oldest.id).inlineBytes
        var changed = false

        try RetentionPolicy(maxTotalBytes: cap).enforceTotalCap(
            store: store, blobs: blobs, search: search, protectedIDs: [],
            withCommitFence: { operation in
                if !changed {
                    changed = true
                    let updated = try store.update(
                        id: newer.id, with: .text(String(repeating: "x", count: 2_048)),
                        now: Date(timeIntervalSince1970: 2)
                    )
                    XCTAssertEqual(updated.preview, newer.preview)
                    XCTAssertEqual(updated.modified, newer.modified)
                }
                try operation()
            }
        )

        XCTAssertThrowsError(try store.body(for: oldest.id))
        XCTAssertNoThrow(try store.body(for: newer.id))
        XCTAssertLessThanOrEqual(try store.storageFootprint(for: newer.id).inlineBytes, cap)
    }

    func testTotalCapDefersRepeatedlyInvalidatedBudgetWithoutDeletingHistory() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let original = try store.append(.text("keep original payload"))
        var commits = 0

        try RetentionPolicy(maxTotalBytes: 0).enforceTotalCap(
            store: store, blobs: blobs, search: search, protectedIDs: [],
            withCommitFence: { operation in
                commits += 1
                _ = try store.append(.text("concurrent writer payload"))
                try operation()
            }
        )

        XCTAssertGreaterThan(commits, 0)
        XCTAssertLessThanOrEqual(commits, 4)
        XCTAssertNoThrow(try store.body(for: original.id))
        XCTAssertEqual(try store.list(limit: 10).count, commits + 1)
    }

    func testTotalCapPreservesProtectedOwnerAndSharedBlob() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let blobID = try blobs.write(Data(repeating: 7, count: 256))
        let old = try store.append(.image(blobID: blobID, width: 1, height: 1), now: Date(timeIntervalSince1970: 1))
        let pinned = try store.append(.image(blobID: blobID, width: 1, height: 1), now: Date(timeIntervalSince1970: 2))

        try RetentionPolicy(maxTotalBytes: 0).enforce(
            store: store, blobs: blobs, search: search, protectedIDs: [pinned.id]
        )

        XCTAssertThrowsError(try store.body(for: old.id))
        XCTAssertNoThrow(try store.body(for: pinned.id))
        XCTAssertTrue(try blobs.contains(id: blobID))
    }
}
