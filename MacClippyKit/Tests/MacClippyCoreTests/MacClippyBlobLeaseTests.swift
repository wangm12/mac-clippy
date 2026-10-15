import CryptoKit
import Foundation
import XCTest

import MacClippyCore

final class MacClippyBlobLeaseTests: XCTestCase {
    func testPerBlobLeaseDefersDeleteUntilLastRelease() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try BlobStore(rootURL: root, key: testKey())
        let second = try BlobStore(rootURL: root, key: testKey())
        let blobID = try first.write(Data([1, 2, 3]), id: "leased-blob")
        let firstLease = try first.acquireReadLease(for: [blobID])
        let secondLease = try second.acquireReadLease(for: [blobID])
        let deferred = LockedValues<String>()
        second.setDeferredDeleteHandler { deferred.append($0) }

        try second.delete(id: blobID)
        XCTAssertTrue(try first.contains(id: blobID))
        firstLease.release()
        XCTAssertTrue(deferred.values.isEmpty, "the second reader still owns the file")

        secondLease.release()
        XCTAssertEqual(deferred.values, [blobID])
        XCTAssertTrue(
            try first.contains(id: blobID),
            "the handler schedules reference revalidation; it does not unlink"
        )

        try second.delete(id: blobID)
        XCTAssertFalse(try first.contains(id: blobID))
    }

    func testRootLeaseProtectsEveryBlobAcrossSymlinkedStoreRoots() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let actualRoot = root.appendingPathComponent("blobs", isDirectory: true)
        let aliasRoot = root.appendingPathComponent("blob-alias", isDirectory: true)
        let first = try BlobStore(rootURL: actualRoot, key: testKey())
        try FileManager.default.createSymbolicLink(at: aliasRoot, withDestinationURL: actualRoot)
        let second = try BlobStore(rootURL: aliasRoot, key: testKey())
        let blobID = try first.write(Data([4, 5, 6]), id: "root-leased-blob")
        let deferred = LockedValues<String>()
        second.setDeferredDeleteHandler { deferred.append($0) }
        let lease = try second.acquireRootReadLease()

        try first.delete(id: blobID)
        _ = try first.write(Data([9]), id: "new-during-backup")
        XCTAssertThrowsError(try first.write(Data([9]), id: blobID)) { error in
            guard let blobError = error as? MacClippyBlobError else {
                return XCTFail("expected an active-read-lease error, got \(error)")
            }
            if case .activeReadLease = blobError { return }
            XCTFail("expected an active-read-lease error, got \(blobError)")
        }
        XCTAssertTrue(try second.contains(id: blobID))
        XCTAssertTrue(deferred.values.isEmpty)

        lease.release()
        XCTAssertEqual(deferred.values, [blobID])
        XCTAssertTrue(try first.contains(id: blobID))
        XCTAssertEqual(try first.read(id: blobID), Data([4, 5, 6]))
    }

    func testDeferredDeleteWaitsForPerBlobLeaseWhenRootLeaseEnds() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BlobStore(rootURL: root, key: testKey())
        let blobID = try store.write(Data([7]), id: "both-leases")
        let deferred = LockedValues<String>()
        store.setDeferredDeleteHandler { deferred.append($0) }
        let rootLease = try store.acquireRootReadLease()
        let blobLease = try store.acquireReadLease(for: [blobID])

        try store.delete(id: blobID)
        rootLease.release()
        XCTAssertTrue(deferred.values.isEmpty)
        blobLease.release()
        XCTAssertEqual(deferred.values, [blobID])
    }

    func testEligibleDeferredDeleteIsDeliveredWhenHandlerIsInstalledLate() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BlobStore(rootURL: root, key: testKey())
        let blobID = try store.write(Data([8]), id: "late-handler")
        let lease = try store.acquireReadLease(for: [blobID])
        try store.delete(id: blobID)
        lease.release()

        let deferred = LockedValues<String>()
        store.setDeferredDeleteHandler { deferred.append($0) }
        XCTAssertEqual(deferred.values, [blobID])
        XCTAssertTrue(try store.contains(id: blobID))
    }

    func testBlobIdentifiersCannotOverwriteExistingAuthenticatedPayloads() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try BlobStore(rootURL: root, key: testKey())
        let blobID = try store.write(Data([1, 2, 3]), id: "immutable-payload")

        XCTAssertThrowsError(try store.write(Data([9, 9, 9]), id: blobID))
        XCTAssertEqual(try store.read(id: blobID), Data([1, 2, 3]))
    }

    private func testKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyBlobLeaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }

    func append(_ value: Value) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }
}
