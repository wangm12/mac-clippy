import CryptoKit
import Foundation
import XCTest

import MacClippyCore

final class MacClippyReconciliationTests: XCTestCase {
    func testDetectsAndRemovesOrphanBlobs() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        // Referenced blob: attached to a record via the legacy envelope.
        let referencedBlobID = try blobs.write(Data(repeating: 1, count: 16))
        _ = try store.append(.image(blobID: referencedBlobID, width: 1, height: 1), now: Date(timeIntervalSince1970: 1))

        // Orphan blob: written to disk but never attached to any record.
        let orphanBlobID = try blobs.write(Data(repeating: 2, count: 16))
        XCTAssertTrue(try blobs.contains(id: orphanBlobID))

        let detected = try MacClippyReconciliation.detect(store: store, search: search, blobs: blobs)
        XCTAssertEqual(detected.orphanBlobIDs, [orphanBlobID])
        XCTAssertTrue(detected.orphanFTSRecordIDs.isEmpty)

        let reconciled = try MacClippyReconciliation.reconcile(
            store: store,
            search: search,
            blobs: blobs,
            deleteBlob: { id in try blobs.delete(id: id) }
        )
        XCTAssertEqual(reconciled.orphanBlobIDs, [orphanBlobID])
        XCTAssertFalse(try blobs.contains(id: orphanBlobID))
        XCTAssertTrue(try blobs.contains(id: referencedBlobID))
    }

    func testDetectsAndRemovesOrphanFTSRows() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        // Live record + matching FTS row.
        let liveMeta = try store.append(.text("live"), now: Date(timeIntervalSince1970: 1))
        try search.insert(id: liveMeta.id, text: "live")

        // Orphan FTS row: indexed but no clipboard record exists.
        let orphanID = RecordID.generate()
        try search.insert(id: orphanID, text: "orphan")
        XCTAssertEqual(try search.search(query: "orphan", limit: 10).map(\.id), [orphanID])

        let detected = try MacClippyReconciliation.detect(store: store, search: search, blobs: blobs)
        XCTAssertEqual(detected.orphanFTSRecordIDs, [orphanID])
        XCTAssertTrue(detected.orphanBlobIDs.isEmpty)
        XCTAssertEqual(detected.missingFTSRecordIDs, [])

        _ = try MacClippyReconciliation.reconcile(
            store: store,
            search: search,
            blobs: blobs,
            deleteBlob: { _ in }
        )

        XCTAssertTrue(try search.search(query: "orphan", limit: 10).isEmpty)
        XCTAssertEqual(try search.search(query: "live", limit: 10).map(\.id), [liveMeta.id])
    }

    func testDetectsMissingFTSForTextButNotUnsearchableImages() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        let blobID = try blobs.write(Data(repeating: 1, count: 16))
        _ = try store.append(.image(blobID: blobID, width: 4, height: 4), now: Date(timeIntervalSince1970: 1))
        let text = try store.append(.text("needs an index row"), now: Date(timeIntervalSince1970: 2))

        let detected = try MacClippyReconciliation.detect(store: store, search: search, blobs: blobs)
        XCTAssertEqual(detected.missingFTSRecordIDs, [text.id])
        XCTAssertEqual(detected.missingFTSRecordCount, 1)
    }

    func testReconciliationDoesNotSkipOrphanFTSRowsWhenDeletingPages() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        for _ in 0..<512 {
            try search.insert(id: RecordID.generate(), text: "orphan")
        }

        let result = try MacClippyReconciliation.reconcile(
            store: store,
            search: search,
            blobs: blobs,
            deleteBlob: { _ in }
        )

        XCTAssertEqual(result.orphanFTSRecordCount, 512)
        XCTAssertTrue(try search.search(query: "orphan", limit: 10).isEmpty)
        XCTAssertEqual(try search.databaseRowCount(), 0)
    }

    func testRepresentationBlobIDsAreCountedAsReferenced() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        // Spill a representation payload to BlobStore; the spilled blob is
        // referenced by the representation side table, not the legacy
        // envelope, so reconciliation must read allRepresentationBlobIDs to
        // avoid deleting it.
        let spilledBlobID = try blobs.write(Data(repeating: 3, count: 16))
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.tiff", payloadBytes: nil, blobID: spilledBlobID)
        ]
        _ = try store.append(.text("spilled"), representations: representations, now: Date(timeIntervalSince1970: 1))

        let detected = try MacClippyReconciliation.detect(store: store, search: search, blobs: blobs)
        XCTAssertTrue(detected.orphanBlobIDs.isEmpty, "spilled representation blob should be referenced")
        XCTAssertTrue(try blobs.contains(id: spilledBlobID))
    }

    func testDetectsReferencedBlobMissingFromDiskWithoutDeletingTheRecord() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        let missingBlobID = try blobs.write(Data(repeating: 7, count: 16))
        _ = try store.append(.image(blobID: missingBlobID, width: 1, height: 1))
        try blobs.delete(id: missingBlobID)

        let detected = try MacClippyReconciliation.detect(store: store, search: search, blobs: blobs)
        XCTAssertEqual(detected.missingBlobIDs, [missingBlobID])
        XCTAssertTrue(detected.orphanBlobIDs.isEmpty)
        XCTAssertFalse(detected.isEmpty)

        let reconciled = try MacClippyReconciliation.reconcile(
            store: store,
            search: search,
            blobs: blobs,
            deleteBlob: { id in try blobs.delete(id: id) }
        )
        XCTAssertEqual(reconciled.missingBlobIDs, [missingBlobID])
        XCTAssertFalse(try store.list(limit: 10).isEmpty)
    }

    func testReconciliationFailsClosedWhenImageEnvelopeCannotBeDecoded() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(database: database, deviceKey: testKey())
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let blobID = try blobs.write(Data(repeating: 8, count: 16))
        _ = try store.append(.image(blobID: blobID, width: 1, height: 1))
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET envelope = ?",
                arguments: [Data([0x01, 0x02, 0x03])]
            )
        }

        XCTAssertThrowsError(try MacClippyReconciliation.detect(store: store, search: search, blobs: blobs))
        XCTAssertTrue(try blobs.contains(id: blobID), "a corrupt record must not make its Blob eligible for cleanup")
    }

    func testReconciliationFailsClosedWhenContentKindIsInvalid() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(database: database, deviceKey: testKey())
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let blobID = try blobs.write(Data(repeating: 9, count: 16))
        let meta = try store.append(.image(blobID: blobID, width: 1, height: 1))

        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET content_kind = ? WHERE id = ?",
                arguments: ["unknown", meta.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.contentKinds(for: [meta.id]))
        XCTAssertThrowsError(try MacClippyReconciliation.detect(store: store, search: search, blobs: blobs))
        XCTAssertTrue(try blobs.contains(id: blobID), "an invalid discriminator must not make its Blob eligible for cleanup")
    }

    func testFailedOrphanCleanupIsReportedAndLeavesTheBlobForRetry() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let orphanBlobID = try blobs.write(Data(repeating: 4, count: 16))

        let result = try MacClippyReconciliation.reconcile(
            store: store,
            search: search,
            blobs: blobs,
            deleteBlob: { _ in throw CleanupError.failed }
        )

        XCTAssertEqual(result.orphanBlobIDs, [orphanBlobID])
        XCTAssertEqual(result.failedBlobCleanupIDs, [orphanBlobID])
        XCTAssertTrue(result.failedFTSCleanupIDs.isEmpty)
        XCTAssertTrue(try blobs.contains(id: orphanBlobID))
    }

    func testReconciliationRevalidatesOrphanBeforeReportingOrDeleting() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let candidateID = try blobs.write(Data(repeating: 5, count: 16))

        var deleteCalled = false
        let result = try MacClippyReconciliation.reconcile(
            store: store,
            search: search,
            blobs: blobs,
            deleteBlob: { _ in deleteCalled = true },
            isBlobStillUnreferenced: { id in
                XCTAssertEqual(id, candidateID)
                return false
            }
        )

        XCTAssertTrue(result.orphanBlobIDs.isEmpty)
        XCTAssertFalse(deleteCalled)
        XCTAssertTrue(try blobs.contains(id: candidateID))
    }

    func testEmptyStoreHasNoOrphans() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        let detected = try MacClippyReconciliation.detect(store: store, search: search, blobs: blobs)
        XCTAssertTrue(detected.isEmpty)
    }

    func testBlobEnumerationPropagatesUnavailableRoot() throws {
        let root = try temporaryDirectory()
        let blobs = try BlobStore(rootURL: root, key: testKey())
        try FileManager.default.removeItem(at: root)

        XCTAssertThrowsError(try blobs.forEachID { _ in })
    }

    func testLargeOrphanScanKeepsDiagnosticsBoundedAndCleansEveryCandidate() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        for index in 0..<300 {
            _ = try blobs.write(Data([UInt8(index % 255)]), id: "orphan-\(index)")
        }

        let detected = try MacClippyReconciliation.detect(store: store, search: search, blobs: blobs)
        XCTAssertEqual(detected.orphanBlobCount, 300)
        XCTAssertEqual(detected.orphanBlobIDs.count, 256)

        var deletedIDs = Set<String>()
        let reconciled = try MacClippyReconciliation.reconcile(
            store: store,
            search: search,
            blobs: blobs,
            deleteBlob: { id in
                deletedIDs.insert(id)
                try blobs.delete(id: id)
            }
        )
        XCTAssertEqual(reconciled.orphanBlobCount, 300)
        XCTAssertEqual(deletedIDs.count, 300)
        XCTAssertFalse(try blobs.contains(id: "orphan-0"))
        XCTAssertFalse(try blobs.contains(id: "orphan-299"))
    }

    private func clipboardStore() throws -> ClipboardStore {
        try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: testKey(),
            deviceID: try XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
    }

    private func searchStore() throws -> SearchStore {
        try SearchStore(database: MacClippyDatabase(inMemory: true))
    }

    private func testKey() -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 9, count: 32))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyReconciliationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private enum CleanupError: Error {
        case failed
    }
}
