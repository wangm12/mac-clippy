import CryptoKit
import Foundation
import XCTest

@testable import MacClippyCore

final class MacClippyImageCapSharedBlobTests: XCTestCase {
    func testSharedPrimaryBlobAtExactUniqueImageCapDeletesNothing() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let sharedBlob = try fixture.blobs.write(Data(repeating: 7, count: 4_096))
        let first = try appendImage(sharedBlob, at: 1, in: fixture.store)
        let second = try appendImage(sharedBlob, at: 2, in: fixture.store)
        let uniqueBytes = try fixture.blobs.byteSizeChecked(id: sharedBlob)

        try RetentionPolicy(maxImageBytes: uniqueBytes).enforce(
            store: fixture.store,
            blobs: fixture.blobs,
            search: fixture.search
        )

        XCTAssertEqual(Set(try fixture.store.metas(for: [first.id, second.id]).map(\.id)), [first.id, second.id])
        XCTAssertTrue(try fixture.blobs.contains(id: sharedBlob))
    }

    func testImageUsageBelowCapDeletesNothing() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let blob = try fixture.blobs.write(Data(repeating: 6, count: 512))
        let record = try appendImage(blob, at: 1, in: fixture.store)
        let cap = try fixture.blobs.byteSizeChecked(id: blob) + 1

        try RetentionPolicy(maxImageBytes: cap).enforce(
            store: fixture.store,
            blobs: fixture.blobs,
            search: fixture.search
        )

        XCTAssertEqual(try fixture.store.metas(for: [record.id]).map(\.id), [record.id])
        XCTAssertTrue(try fixture.blobs.contains(id: blob))
    }

    func testSharedPrimaryBlobOnlyReducesCapAfterItsFinalOwnerIsDeleted() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let sharedBlob = try fixture.blobs.write(Data(repeating: 3, count: 128))
        let uniqueBlob = try fixture.blobs.write(Data(repeating: 4, count: 32))
        let firstOwner = try appendImage(sharedBlob, at: 1, in: fixture.store)
        let lastSharedOwner = try appendImage(sharedBlob, at: 2, in: fixture.store)
        let uniqueOwner = try appendImage(uniqueBlob, at: 3, in: fixture.store)
        let cap = try fixture.blobs.byteSizeChecked(id: uniqueBlob)

        try RetentionPolicy(maxImageBytes: cap).enforce(
            store: fixture.store,
            blobs: fixture.blobs,
            search: fixture.search
        )

        XCTAssertTrue(try fixture.store.metas(for: [firstOwner.id, lastSharedOwner.id]).isEmpty)
        XCTAssertEqual(try fixture.store.metas(for: [uniqueOwner.id]).map(\.id), [uniqueOwner.id])
        XCTAssertFalse(try fixture.blobs.contains(id: sharedBlob))
        XCTAssertTrue(try fixture.blobs.contains(id: uniqueBlob))
    }

    func testProtectedOwnerPreventsSharedBlobFromBeingCreditedAsReclaimed() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let sharedBlob = try fixture.blobs.write(Data(repeating: 5, count: 256))
        let firstOwner = try appendImage(sharedBlob, at: 1, in: fixture.store)
        let secondOwner = try appendImage(sharedBlob, at: 2, in: fixture.store)
        let protectedOwner = try appendImage(sharedBlob, at: 3, in: fixture.store)

        try RetentionPolicy(maxImageBytes: 0).enforce(
            store: fixture.store,
            blobs: fixture.blobs,
            search: fixture.search,
            protectedIDs: [protectedOwner.id]
        )

        XCTAssertTrue(try fixture.store.metas(for: [firstOwner.id, secondOwner.id]).isEmpty)
        XCTAssertEqual(try fixture.store.metas(for: [protectedOwner.id]).map(\.id), [protectedOwner.id])
        XCTAssertTrue(try fixture.blobs.contains(id: sharedBlob))
    }

    func testSharedRepresentationBlobIsNotCreditedWhileAnotherImageOwnerKeepsIt() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let firstPrimary = try fixture.blobs.write(Data(repeating: 1, count: 40))
        let secondPrimary = try fixture.blobs.write(Data(repeating: 2, count: 40))
        let sharedRepresentationBlob = try fixture.blobs.write(Data(repeating: 6, count: 160))
        let representation = MacClippyClipboardRepresentation(
            uti: "com.example.shared-image-representation",
            payloadBytes: nil,
            blobID: sharedRepresentationBlob
        )
        let first = try fixture.store.append(
            .image(blobID: firstPrimary, width: 1, height: 1),
            representations: [representation],
            now: Date(timeIntervalSince1970: 1)
        )
        let second = try fixture.store.append(
            .image(blobID: secondPrimary, width: 1, height: 1),
            representations: [representation],
            now: Date(timeIntervalSince1970: 2)
        )
        let cap = try fixture.blobs.byteSizeChecked(id: secondPrimary)
            + fixture.blobs.byteSizeChecked(id: sharedRepresentationBlob)

        try RetentionPolicy(maxImageBytes: cap).enforce(
            store: fixture.store,
            blobs: fixture.blobs,
            search: fixture.search
        )

        XCTAssertTrue(try fixture.store.metas(for: [first.id]).isEmpty)
        XCTAssertEqual(try fixture.store.metas(for: [second.id]).map(\.id), [second.id])
        XCTAssertFalse(try fixture.blobs.contains(id: firstPrimary))
        XCTAssertTrue(try fixture.blobs.contains(id: secondPrimary))
        XCTAssertTrue(try fixture.blobs.contains(id: sharedRepresentationBlob))
    }

    func testSharedOwnerAcrossDeletionPagesIsCreditedOnlyOnFinalPage() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let sharedBlob = try fixture.blobs.write(Data(repeating: 8, count: 80))
        var recordIDs: [RecordID] = []
        for index in 0..<257 {
            recordIDs.append(try appendImage(sharedBlob, at: Double(index + 1), in: fixture.store).id)
        }
        var commitCount = 0

        try RetentionPolicy(maxImageBytes: 0).enforce(
            store: fixture.store,
            blobs: fixture.blobs,
            search: fixture.search,
            withCommitFence: { operation in
                commitCount += 1
                try operation()
            }
        )

        XCTAssertEqual(commitCount, 2)
        XCTAssertEqual(try fixture.store.databaseRowCount(), 0)
        XCTAssertFalse(try fixture.blobs.contains(id: sharedBlob))
        XCTAssertTrue(try fixture.store.metas(for: recordIDs).isEmpty)
    }

    func testConcurrentOwnerAddedAtCommitFencePreventsPrematureSharedBlobCredit() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let sharedBlob = try fixture.blobs.write(Data(repeating: 9, count: 96))
        let otherBlob = try fixture.blobs.write(Data(repeating: 2, count: 96))
        let firstOwner = try appendImage(sharedBlob, at: 1, in: fixture.store)
        let otherOwner = try appendImage(otherBlob, at: 2, in: fixture.store)
        let bytesPerBlob = try fixture.blobs.byteSizeChecked(id: sharedBlob)
        var concurrentOwner: ClipboardItemMeta?
        var inserted = false

        try RetentionPolicy(maxImageBytes: bytesPerBlob).enforce(
            store: fixture.store,
            blobs: fixture.blobs,
            search: fixture.search,
            withCommitFence: { operation in
                if !inserted {
                    inserted = true
                    concurrentOwner = try fixture.store.append(
                        .image(blobID: sharedBlob, width: 1, height: 1),
                        now: Date(timeIntervalSince1970: 3)
                    )
                }
                try operation()
            }
        )

        let concurrentID = try XCTUnwrap(concurrentOwner?.id)
        XCTAssertEqual(Set(try fixture.store.metas(for: [concurrentID]).map(\.id)), [concurrentID])
        XCTAssertTrue(try fixture.store.metas(for: [firstOwner.id, otherOwner.id]).isEmpty)
        XCTAssertTrue(try fixture.blobs.contains(id: sharedBlob))
        XCTAssertFalse(try fixture.blobs.contains(id: otherBlob))
    }

    func testChangedCandidateFootprintIsRejectedAtCommitRevalidation() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let originalBlob = try fixture.blobs.write(Data(repeating: 1, count: 72))
        let replacementBlob = try fixture.blobs.write(Data(repeating: 3, count: 72))
        let nextBlob = try fixture.blobs.write(Data(repeating: 4, count: 72))
        let changedCandidate = try appendImage(originalBlob, at: 1, in: fixture.store)
        let nextCandidate = try appendImage(nextBlob, at: 2, in: fixture.store)
        let cap = try fixture.blobs.byteSizeChecked(id: nextBlob)
        var changed = false

        try RetentionPolicy(maxImageBytes: cap).enforce(
            store: fixture.store,
            blobs: fixture.blobs,
            search: fixture.search,
            withCommitFence: { operation in
                if !changed {
                    changed = true
                    _ = try fixture.store.update(
                        id: changedCandidate.id,
                        with: .image(blobID: replacementBlob, width: 1, height: 1),
                        now: Date(timeIntervalSince1970: 10)
                    )
                }
                try operation()
            }
        )

        XCTAssertEqual(
            try fixture.store.body(for: changedCandidate.id),
            .image(blobID: replacementBlob, width: 1, height: 1)
        )
        XCTAssertThrowsError(try fixture.store.body(for: nextCandidate.id))
        XCTAssertTrue(try fixture.blobs.contains(id: replacementBlob))
        XCTAssertFalse(try fixture.blobs.contains(id: nextBlob))
    }

    func testCancellationAfterPartialImageDeletionDoesNotCreditOrDeleteBlobs() throws {
        let fixture = try makeFixture()
        defer { cleanup(fixture) }

        let firstBlob = try fixture.blobs.write(Data(repeating: 2, count: 64))
        let secondBlob = try fixture.blobs.write(Data(repeating: 4, count: 96))
        let first = try appendImage(firstBlob, at: 1, in: fixture.store)
        let second = try appendImage(secondBlob, at: 2, in: fixture.store)
        try fixture.search.upsert(id: first.id, text: "imagecapfirstmarker")
        try fixture.search.upsert(id: second.id, text: "imagecapsecondmarker")

        try RetentionPolicy(maxImageBytes: 0).enforceImageCap(
            store: fixture.store,
            blobs: fixture.blobs,
            search: fixture.search,
            protectedIDs: [],
            shouldContinue: {
                guard let matches = try? fixture.search.search(
                    query: "imagecapfirstmarker",
                    limit: 10
                ) else {
                    return false
                }
                return matches.contains { $0.id == first.id }
            }
        )

        XCTAssertTrue(try fixture.store.metas(for: [first.id]).isEmpty)
        XCTAssertEqual(try fixture.store.metas(for: [second.id]).map(\.id), [second.id])
        XCTAssertTrue(try fixture.blobs.contains(id: firstBlob))
        XCTAssertTrue(try fixture.blobs.contains(id: secondBlob))
        XCTAssertEqual(try fixture.store.pendingDeletionCount(), 1)
    }
}

private extension MacClippyImageCapSharedBlobTests {
    struct Fixture {
        let root: URL
        let database: MacClippyDatabase
        let store: ClipboardStore
        let search: SearchStore
        let blobs: BlobStore
    }

    func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyImageCap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let key = SymmetricKey(data: Data((0..<32).map { _ in UInt8.random(in: 0...UInt8.max) }))
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(database: database, deviceKey: key)
        let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
        let blobs = try BlobStore(rootURL: root.appendingPathComponent("blobs"), key: key)
        return Fixture(root: root, database: database, store: store, search: search, blobs: blobs)
    }

    func appendImage(_ blobID: String, at timestamp: Double, in store: ClipboardStore) throws -> ClipboardItemMeta {
        try store.append(
            .image(blobID: blobID, width: 1, height: 1),
            now: Date(timeIntervalSince1970: timestamp)
        )
    }

    func cleanup(_ fixture: Fixture) {
        try? fixture.database.queue.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }
}
