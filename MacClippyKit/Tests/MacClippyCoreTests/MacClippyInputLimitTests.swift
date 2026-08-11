import CryptoKit
import Foundation
import XCTest

import MacClippyCore

final class MacClippyInputLimitTests: XCTestCase {
    func testDefaultInputLimitsAllowTheDocumentedLargeImageRangeButBoundIt() {
        let limits = MacClippyPasteboardInputLimits.default
        XCTAssertGreaterThanOrEqual(limits.maxRepresentationBytes, 100 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(limits.maxChangeBytes, 256 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(limits.maxHistoryBytes, 4 * 1_024 * 1_024 * 1_024)
        XCTAssertLessThanOrEqual(limits.maxRepresentationBytes, limits.maxChangeBytes)
        XCTAssertLessThanOrEqual(limits.maxRecordBytes, limits.maxHistoryBytes)
    }

    func testStoreRejectsRepresentationAndRecordAboveConfiguredLimits() throws {
        let limits = MacClippyPasteboardInputLimits(
            maxRepresentationBytes: 8,
            maxChangeBytes: 12,
            maxRecordBytes: 16,
            maxHistoryBytes: 32
        )
        let store = try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: SymmetricKey(data: Data(repeating: 1, count: 32)),
            inputLimits: limits
        )
        XCTAssertThrowsError(try store.append(
            .text("small"),
            representations: [MacClippyClipboardRepresentation(uti: "public.data", payloadBytes: Data(repeating: 1, count: 9))]
        )) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .inputTooLarge)
        }
        XCTAssertThrowsError(try store.append(.text(String(repeating: "x", count: 32)))) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .inputTooLarge)
        }
        XCTAssertTrue(try store.list(limit: 10).isEmpty)
    }

    func testPinboardAndSnippetStoresBoundUserAuthoredPayloads() throws {
        let key = SymmetricKey(data: Data(repeating: 4, count: 32))
        let pinboards = try PinboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: key
        )
        let oversizedName = String(
            repeating: "n",
            count: MacClippyCollectionLimits.maxNameUTF8Bytes + 1
        )
        XCTAssertThrowsError(try pinboards.create(name: oversizedName)) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .inputTooLarge)
        }

        let oversizedBoard = Pinboard(
            name: "Large board",
            itemIDs: (0...MacClippyCollectionLimits.maxPinboardItems).map { _ in .generate() }
        )
        XCTAssertThrowsError(try pinboards.update(oversizedBoard)) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .inputTooLarge)
        }

        let snippets = try SnippetStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: key
        )
        let oversizedBody = String(
            repeating: "b",
            count: MacClippyCollectionLimits.maxSnippetBodyUTF8Bytes + 1
        )
        XCTAssertThrowsError(try snippets.create(name: "Large", body: oversizedBody)) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .inputTooLarge)
        }
        let oversizedTrigger = String(
            repeating: "t",
            count: MacClippyCollectionLimits.maxSnippetTriggerUTF8Bytes + 1
        )
        XCTAssertThrowsError(try snippets.create(name: "Trigger", body: "body", trigger: oversizedTrigger)) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .inputTooLarge)
        }
    }

    func testClipboardStoreBoundsRepresentationMetadata() throws {
        let limits = MacClippyPasteboardInputLimits(
            maxUTIBytes: 8,
            maxRepresentationsPerRecord: 1
        )
        let store = try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: SymmetricKey(data: Data(repeating: 5, count: 32)),
            inputLimits: limits
        )

        XCTAssertThrowsError(try store.append(
            .text("bounded"),
            representations: [
                MacClippyClipboardRepresentation(uti: "text", payloadBytes: Data("one".utf8)),
                MacClippyClipboardRepresentation(uti: "html", payloadBytes: Data("two".utf8))
            ]
        )) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .inputTooLarge)
        }
        XCTAssertThrowsError(try store.append(
            .text("bounded"),
            representations: [
                MacClippyClipboardRepresentation(uti: "uti-too-long", payloadBytes: Data("one".utf8))
            ]
        )) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .inputTooLarge)
        }
    }

    func testTotalRetentionCapRemovesOldestUnpinnedPayloadAndPreservesPinboardItems() throws {
        let key = SymmetricKey(data: Data(repeating: 2, count: 32))
        let store = try ClipboardStore(database: MacClippyDatabase(inMemory: true), deviceKey: key)
        let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyInputLimitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: key)
        let oldBlob = try blobs.write(Data(repeating: 1, count: 64))
        let protectedBlob = try blobs.write(Data(repeating: 2, count: 64))
        let old = try store.append(.image(blobID: oldBlob, width: 1, height: 1), now: Date(timeIntervalSince1970: 1))
        let protected = try store.append(.image(blobID: protectedBlob, width: 1, height: 1), now: Date(timeIntervalSince1970: 2))
        try search.insert(id: old.id, text: "old")
        try search.insert(id: protected.id, text: "protected")
        let pinboards = try PinboardStore(database: MacClippyDatabase(inMemory: true), deviceKey: key)
        let board = try pinboards.create(name: "Keep")
        try pinboards.addItem(protected.id, to: board.id)

        try RetentionPolicy(maxTotalBytes: 80).enforce(store: store, blobs: blobs, search: search, pinboards: pinboards)

        XCTAssertThrowsError(try store.body(for: old.id))
        XCTAssertEqual(try store.body(for: protected.id), .image(blobID: protectedBlob, width: 1, height: 1))
        XCTAssertTrue(try blobs.contains(id: protectedBlob))
    }

    func testTotalRetentionCapSurfacesUnreadableRecordsInsteadOfSkippingThem() throws {
        let key = SymmetricKey(data: Data(repeating: 3, count: 32))
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(database: database, deviceKey: key)
        _ = try store.append(.text("record"))
        let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyInputLimitCorrupt-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: key)

        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET envelope = ?",
                arguments: [Data([0x01, 0x02, 0x03])]
            )
        }

        XCTAssertThrowsError(
            try RetentionPolicy(maxTotalBytes: 1).enforce(
                store: store,
                blobs: blobs,
                search: search
            )
        )
        XCTAssertEqual(try store.list(limit: 10).count, 1)
    }
}
