import CryptoKit
import Foundation
import XCTest

import GRDB
import MacClippyCore

final class MacClippyCaptureRollbackTests: XCTestCase {
    func testAppendIsAtomicAndLeavesNoVisibleRecordOnFailure() throws {
        let store = try clipboardStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        struct SpillError: Error {}

        let bigPayload = Data(repeating: 0x07, count: MacClippyClipboardRepresentationLimits.inlineByteCeiling + 1)
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.tiff", payloadBytes: bigPayload)
        ]

        XCTAssertThrowsError(try store.append(
            .text("should-not-persist"),
            representations: representations,
            spillPayload: { _ in throw SpillError() },
            now: Date(timeIntervalSince1970: 1)
        ))
        XCTAssertTrue(try store.list(limit: 10).isEmpty)
        XCTAssertTrue(try store.allRepresentationBlobIDs().isEmpty)
        let blobFiles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(blobFiles.isEmpty, "spill failure must not leak a blob file")
    }

    func testAppendCleansSpilledBlobsWhenTransactionFails() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(database: database, deviceKey: testKey())
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        try database.queue.write { connection in
            try connection.execute(sql: "DROP TABLE clipboard_representations")
        }

        let bigPayload = Data(repeating: 0x07, count: MacClippyClipboardRepresentationLimits.inlineByteCeiling + 1)
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.tiff", payloadBytes: bigPayload),
            MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("small".utf8))
        ]
        var deletedBlobIDs: [String] = []
        let spilledBlobIDHolder = NSMutableArray()

        XCTAssertThrowsError(try store.append(
            .text("should-not-persist"),
            representations: representations,
            spillPayload: { [blobs] data in
                let id = try blobs.write(data)
                spilledBlobIDHolder.add(id)
                return id
            },
            deleteSpilledPayload: { id in
                deletedBlobIDs.append(id)
                try? blobs.delete(id: id)
            },
            now: Date(timeIntervalSince1970: 1)
        ))

        XCTAssertEqual(spilledBlobIDHolder.count, 1)
        let spilledID = spilledBlobIDHolder[0] as? String
        XCTAssertNotNil(spilledID)
        XCTAssertEqual(deletedBlobIDs, [spilledID].compactMap { $0 })
        if let spilledID {
            XCTAssertFalse(try blobs.contains(id: spilledID))
        }
        XCTAssertTrue(try store.list(limit: 10).isEmpty)
        let blobFiles = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(blobFiles.isEmpty, "transaction failure must not leak a spilled blob")
    }

    func testAppendCleansSpilledBlobsWhenSpillFailsMidStream() throws {
        let store = try clipboardStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        struct SpillError: Error {}
        let firstBlobID = try blobs.write(Data(repeating: 0x01, count: 16))
        let bigPayload = Data(repeating: 0x07, count: MacClippyClipboardRepresentationLimits.inlineByteCeiling + 1)
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.tiff", payloadBytes: bigPayload),
            MacClippyClipboardRepresentation(uti: "public.png", payloadBytes: bigPayload)
        ]

        var spillCallIndex = 0
        var deletedBlobIDs: [String] = []
        XCTAssertThrowsError(try store.append(
            .text("should-not-persist"),
            representations: representations,
            spillPayload: { _ in
                spillCallIndex += 1
                if spillCallIndex == 1 { return firstBlobID }
                throw SpillError()
            },
            deleteSpilledPayload: { id in
                deletedBlobIDs.append(id)
                try? blobs.delete(id: id)
            },
            now: Date(timeIntervalSince1970: 1)
        ))

        XCTAssertEqual(deletedBlobIDs, [firstBlobID])
        XCTAssertFalse(try blobs.contains(id: firstBlobID))
        XCTAssertTrue(try store.list(limit: 10).isEmpty)
        XCTAssertTrue(try store.allRepresentationBlobIDs().isEmpty)
    }

    func testAppendPersistsSourceApplicationAndRepresentationMetadata() throws {
        let store = try clipboardStore()
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("internal".utf8))
        ]
        let meta = try store.append(
            .text("internal"),
            representations: representations,
            sourceAppBundleID: "com.macallyouneed.macclippy",
            now: Date(timeIntervalSince1970: 1)
        )
        XCTAssertEqual(meta.sourceAppBundleID, "com.macallyouneed.macclippy")
        XCTAssertEqual(try store.representations(for: meta.id).map(\.uti), ["public.utf8-plain-text"])
    }

    func testAppendPersistsSpilledRepresentationReferenceMetadata() throws {
        let store = try clipboardStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())

        let spilledBlobID = try blobs.write(Data(repeating: 3, count: 16))
        let representations = [
            MacClippyClipboardRepresentation(
                uti: "public.tiff",
                payloadBytes: nil,
                blobID: spilledBlobID,
                payloadState: .spilled
            )
        ]
        let meta = try store.append(
            .text("spilled"),
            representations: representations,
            now: Date(timeIntervalSince1970: 1)
        )

        XCTAssertEqual(try store.allRepresentationBlobIDs(), [spilledBlobID])
        let stored = try store.representations(for: meta.id)
        XCTAssertEqual(stored.first?.blobID, spilledBlobID)
        XCTAssertEqual(stored.first?.payloadState, .spilled)
    }

    private func clipboardStore() throws -> ClipboardStore {
        try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: testKey(),
            deviceID: try XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
    }

    private func testKey() -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 9, count: 32))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyCaptureRollbackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
