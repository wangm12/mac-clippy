import CryptoKit
import Foundation
import GRDB
import MacClippyCore
import XCTest

extension MacClippyCoreTests {
    func testBlobReadDeleteAndRetentionRemovesBlobAndSearch() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let blobID = try blobs.write(Data(repeating: 7, count: 32))
        let meta = try store.append(.image(blobID: blobID, width: 3, height: 4), now: Date(timeIntervalSince1970: 1))
        try search.insert(id: meta.id, text: "image seven")

        let policy = RetentionPolicy(maxItems: 0)
        try policy.enforce(store: store, blobs: blobs, search: search)

        XCTAssertFalse(try blobs.contains(id: blobID))
        XCTAssertThrowsError(try store.body(for: meta.id))
        XCTAssertTrue(try search.search(query: "image", limit: 10).isEmpty)
    }

    func testBlobMetadataAPIsPropagateInvalidIdentifiers() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        XCTAssertThrowsError(try blobs.contains(id: "../outside")) { error in
            XCTAssertEqual(error as? MacClippyBlobError, .invalidIdentifier)
        }
        XCTAssertThrowsError(try blobs.byteSize(id: "../outside")) { error in
            XCTAssertEqual(error as? MacClippyBlobError, .invalidIdentifier)
        }
        XCTAssertThrowsError(try blobs.encryptedURL(id: "../outside")) { error in
            XCTAssertEqual(error as? MacClippyBlobError, .invalidIdentifier)
        }
    }

    func testPinboardItemsAreProtectedFromRetention() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let protected = try store.append(.text("protected"), now: Date(timeIntervalSince1970: 1))
        let removable = try store.append(.text("removable"), now: Date(timeIntervalSince1970: 2))
        let pinboards = try PinboardStore(database: MacClippyDatabase(inMemory: true), deviceKey: testKey())
        let board = try pinboards.create(name: "Keep")
        try pinboards.addItem(protected.id, to: board.id)

        try RetentionPolicy(maxItems: 0).enforce(store: store, blobs: blobs, search: search, pinboards: pinboards)

        XCTAssertEqual(try store.body(for: protected.id), .text("protected"))
        XCTAssertThrowsError(try store.body(for: removable.id))
    }

    func testRetentionFailsClosedWhenPinboardCannotBeDecoded() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let protected = try store.append(.text("protected"), now: Date(timeIntervalSince1970: 1))
        let pinboardDatabase = try MacClippyDatabase(inMemory: true)
        let pinboards = try PinboardStore(database: pinboardDatabase, deviceKey: testKey())
        let board = try pinboards.create(name: "Keep")
        try pinboards.addItem(protected.id, to: board.id)

        try pinboardDatabase.queue.write { connection in
            try connection.execute(
                sql: "UPDATE macclippy_pinboards SET envelope = ? WHERE id = ?",
                arguments: [Data([0x01, 0x02, 0x03]), board.id.rawValue]
            )
        }

        XCTAssertThrowsError(
            try RetentionPolicy(maxItems: 0).enforce(
                store: store,
                blobs: blobs,
                search: search,
                pinboards: pinboards
            )
        )
        XCTAssertEqual(try store.body(for: protected.id), .text("protected"))
    }

    func testRetentionKeepsBlobReferencedByAnotherRecord() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let blobID = try blobs.write(Data(repeating: 5, count: 24))
        let old = try store.append(.image(blobID: blobID, width: 1, height: 1), now: Date(timeIntervalSince1970: 1))
        let newest = try store.append(.image(blobID: blobID, width: 1, height: 1), now: Date(timeIntervalSince1970: 2))

        try RetentionPolicy(maxItems: 1).enforce(store: store, blobs: blobs, search: search)

        XCTAssertThrowsError(try store.body(for: old.id))
        XCTAssertEqual(try store.body(for: newest.id), .image(blobID: blobID, width: 1, height: 1))
        XCTAssertTrue(try blobs.contains(id: blobID))
    }

    func testTotalRetentionCountsSharedBlobOnlyOnce() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let blobID = try blobs.write(Data(repeating: 7, count: 64))
        let first = try store.append(.image(blobID: blobID, width: 1, height: 1), now: Date(timeIntervalSince1970: 1))
        let second = try store.append(.image(blobID: blobID, width: 1, height: 1), now: Date(timeIntervalSince1970: 2))
        let firstFootprint = try store.storageFootprint(for: first.id)
        let secondFootprint = try store.storageFootprint(for: second.id)
        let blobBytes = try blobs.byteSizeChecked(id: blobID)
        let physicalBytes = firstFootprint.inlineBytes + secondFootprint.inlineBytes + blobBytes

        try RetentionPolicy(maxTotalBytes: physicalBytes).enforce(
            store: store,
            blobs: blobs,
            search: search
        )

        XCTAssertNoThrow(try store.body(for: first.id))
        XCTAssertNoThrow(try store.body(for: second.id))
    }

    func testMaxAgeAndImageByteRetention() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let old = try store.append(.text("old"), now: Date(timeIntervalSince1970: 1))
        let imageBlob = try blobs.write(Data(repeating: 3, count: 100))
        let image = try store.append(
            .image(blobID: imageBlob, width: 1, height: 1),
            now: Date(timeIntervalSince1970: 2)
        )
        let imageRecordBlob = try blobs.write(Data(repeating: 4, count: 100))
        let newestImage = try store.append(
            .image(blobID: imageRecordBlob, width: 1, height: 1),
            now: Date(timeIntervalSince1970: 3)
        )

        try RetentionPolicy(maxAgeSeconds: 5, maxImageBytes: blobs.byteSize(id: imageRecordBlob)).enforce(
            store: store, blobs: blobs, search: search, now: Date(timeIntervalSince1970: 7)
        )

        XCTAssertThrowsError(try store.body(for: old.id))
        XCTAssertThrowsError(try store.body(for: image.id))
        XCTAssertEqual(try store.body(for: newestImage.id), .image(blobID: imageRecordBlob, width: 1, height: 1))
        XCTAssertFalse(try blobs.contains(id: imageBlob))
    }

    func testMaxAgeRetentionDeletesAcrossMetadataPagesWithoutMaterializingAllIDs() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        for index in 0 ..< 513 {
            let timestamp = index < 300 ? 0.0 : 9999.0
            _ = try store.append(
                .text("record-\(index)"),
                now: Date(timeIntervalSince1970: timestamp)
            )
        }

        try RetentionPolicy(maxAgeSeconds: 1).enforce(
            store: store,
            blobs: blobs,
            search: search,
            now: Date(timeIntervalSince1970: 10000)
        )

        let remaining = try store.list(limit: 600)
        XCTAssertEqual(remaining.count, 213)
        XCTAssertTrue(remaining.allSatisfy { $0.preview.hasPrefix("record-") })
        XCTAssertFalse(remaining.contains { $0.modified < Date(timeIntervalSince1970: 9999) })
    }

    func testMaxAgeRetentionRevalidatesModifiedRecordsBeforeDeletion() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let record = try store.append(.text("old"), now: Date(timeIntervalSince1970: 1))
        var commitCount = 0

        try RetentionPolicy(maxAgeSeconds: 5).enforce(
            store: store,
            blobs: blobs,
            search: search,
            now: Date(timeIntervalSince1970: 10),
            withCommitFence: { operation in
                commitCount += 1
                if commitCount == 1 {
                    _ = try store.setCustomLabel(
                        id: record.id,
                        label: "kept",
                        now: Date(timeIntervalSince1970: 10)
                    )
                }
                try operation()
            }
        )

        XCTAssertEqual(try store.body(for: record.id), .text("old"))
        XCTAssertEqual(try store.metas(for: [record.id]).first?.customLabel, "kept")
    }

    func testItemRetentionCountsOnlyRecordsActuallyDeleted() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let oldest = try store.append(.text("oldest"), now: Date(timeIntervalSince1970: 1))
        let middle = try store.append(.text("middle"), now: Date(timeIntervalSince1970: 2))
        let newest = try store.append(.text("newest"), now: Date(timeIntervalSince1970: 3))

        try RetentionPolicy(maxItems: 1).enforce(
            store: store,
            blobs: blobs,
            search: search,
            protectedIDs: [],
            protectedIDsProvider: { [oldest.id] }
        )

        XCTAssertNoThrow(try store.body(for: oldest.id))
        XCTAssertThrowsError(try store.body(for: middle.id))
        XCTAssertThrowsError(try store.body(for: newest.id))
    }

    func testItemRetentionRetriesAfterARevalidatedFinalPageCandidateChanges() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        var records: [ClipboardItemMeta] = []
        records.reserveCapacity(257)
        for index in 0 ..< 257 {
            try records.append(store.append(
                .text("record-\(index)"),
                now: Date(timeIntervalSince1970: Double(index))
            ))
        }

        var commitCount = 0
        try RetentionPolicy(maxItems: 1).enforce(
            store: store,
            blobs: blobs,
            search: search,
            withCommitFence: { operation in
                commitCount += 1
                if commitCount == 1 {
                    _ = try store.setCustomLabel(
                        id: records[0].id,
                        label: "changed",
                        now: Date(timeIntervalSince1970: 0.5)
                    )
                } else if commitCount == 2 {
                    _ = try store.setCustomLabel(
                        id: records[256].id,
                        label: "changed",
                        now: Date(timeIntervalSince1970: 256.5)
                    )
                }
                try operation()
            }
        )

        XCTAssertThrowsError(try store.body(for: records[0].id))
        XCTAssertNoThrow(try store.body(for: records[256].id))
        XCTAssertEqual(try store.list(limit: 16).count, 1)
    }

    func testImageRetentionContinuesPastRevalidatedCandidateInSamePage() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let oldestBlob = try blobs.write(Data(repeating: 1, count: 100))
        let middleBlob = try blobs.write(Data(repeating: 2, count: 100))
        let newestBlob = try blobs.write(Data(repeating: 3, count: 100))
        let oldest = try store.append(
            .image(blobID: oldestBlob, width: 1, height: 1),
            now: Date(timeIntervalSince1970: 1)
        )
        let middle = try store.append(
            .image(blobID: middleBlob, width: 1, height: 1),
            now: Date(timeIntervalSince1970: 2)
        )
        let newest = try store.append(
            .image(blobID: newestBlob, width: 1, height: 1),
            now: Date(timeIntervalSince1970: 3)
        )
        let imageBytes = try blobs.byteSizeChecked(id: newestBlob)
        var commitCount = 0

        try RetentionPolicy(maxImageBytes: imageBytes).enforce(
            store: store,
            blobs: blobs,
            search: search,
            withCommitFence: { operation in
                commitCount += 1
                if commitCount == 1 {
                    _ = try store.setCustomLabel(id: oldest.id, label: "changed", now: Date(timeIntervalSince1970: 10))
                }
                try operation()
            }
        )

        XCTAssertNoThrow(try store.body(for: oldest.id))
        XCTAssertThrowsError(try store.body(for: middle.id))
        XCTAssertThrowsError(try store.body(for: newest.id))
    }

    func testTotalRetentionContinuesPastRevalidatedCandidateInSamePage() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let oldest = try store.append(.text("same-size payload"), now: Date(timeIntervalSince1970: 1))
        let middle = try store.append(.text("same-size payload"), now: Date(timeIntervalSince1970: 2))
        let newest = try store.append(.text("same-size payload"), now: Date(timeIntervalSince1970: 3))
        let oneRecordBytes = try store.storageFootprint(for: newest.id).inlineBytes
        var commitCount = 0

        try RetentionPolicy(maxTotalBytes: oneRecordBytes).enforce(
            store: store,
            blobs: blobs,
            search: search,
            withCommitFence: { operation in
                commitCount += 1
                if commitCount == 1 {
                    _ = try store.setCustomLabel(id: oldest.id, label: "changed", now: Date(timeIntervalSince1970: 10))
                }
                try operation()
            }
        )

        XCTAssertNoThrow(try store.body(for: oldest.id))
        XCTAssertThrowsError(try store.body(for: middle.id))
        XCTAssertThrowsError(try store.body(for: newest.id))
    }
}
