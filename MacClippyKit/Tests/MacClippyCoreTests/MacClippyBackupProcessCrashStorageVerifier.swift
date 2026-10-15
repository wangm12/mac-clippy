import CryptoKit
import Foundation
import XCTest

@testable import MacClippyCore

enum RestoreCrashStorageVerifier {
    typealias Support = MacClippyBackupProcessCrashSupport

    private struct Storage {
        let databases: [MacClippyDatabase]
        let clipboard: ClipboardStore
        let search: SearchStore
        let pinboards: PinboardStore
        let snippets: SnippetStore
        let blobs: BlobStore

        init(liveRootURL: URL, key: SymmetricKey) throws {
            let databaseRoot = liveRootURL.appendingPathComponent("databases", isDirectory: true)
            let clipboardDatabase = try MacClippyDatabase(url: databaseRoot.appendingPathComponent("clipboard.sqlite"))
            let searchDatabase = try MacClippyDatabase(url: databaseRoot.appendingPathComponent("search.sqlite"))
            let pinboardsDatabase = try MacClippyDatabase(url: databaseRoot.appendingPathComponent("pinboards.sqlite"))
            let snippetsDatabase = try MacClippyDatabase(url: databaseRoot.appendingPathComponent("snippets.sqlite"))
            databases = [clipboardDatabase, searchDatabase, pinboardsDatabase, snippetsDatabase]
            clipboard = try ClipboardStore(database: clipboardDatabase, deviceKey: key)
            search = try SearchStore(database: searchDatabase)
            pinboards = try PinboardStore(database: pinboardsDatabase, deviceKey: key)
            snippets = try SnippetStore(database: snippetsDatabase, deviceKey: key)
            blobs = try BlobStore(
                rootURL: liveRootURL.appendingPathComponent("blobs", isDirectory: true),
                key: key
            )
        }

        func close() {
            databases.forEach { try? $0.queue.close() }
        }
    }

    static func assertCompleteStorage(
        _ liveRootURL: URL,
        matches expected: Support.GenerationExpectation
    ) throws {
        assertLiveRootShape(liveRootURL)
        let key = try Support.testKey(at: liveRootURL.deletingLastPathComponent())
        let storage = try Storage(liveRootURL: liveRootURL, key: key)
        defer { storage.close() }
        try assertClipboard(storage, matches: expected)
        try assertSearch(storage.search, matches: expected)
        try assertCollections(storage, matches: expected)
        try assertMarkers(liveRootURL, key: key, matches: expected)
        assertJournalAndTransactionArtifactsRemoved(liveRootURL)
    }

    private static func assertLiveRootShape(_ liveRootURL: URL) {
        let rootChildren = (try? FileManager.default.contentsOfDirectory(atPath: liveRootURL.path).sorted()) ?? []
        XCTAssertEqual(
            rootChildren,
            MacClippyBackup.liveComponents.sorted(),
            "Only one complete generation may remain."
        )
    }

    private static func assertClipboard(
        _ storage: Storage,
        matches expected: Support.GenerationExpectation
    ) throws {
        let items = try storage.clipboard.list(limit: 8)
        XCTAssertEqual(Set(items.map(\.id)), expected.recordIDs)
        XCTAssertEqual(items.count, 2, "The fixture must contain exactly two clipboard records.")
        XCTAssertEqual(try storage.clipboard.body(for: expected.textRecordID), .text(expected.textBody))
        try assertTextRepresentation(storage.clipboard, matches: expected)
        try assertImageAttachment(storage, matches: expected)
    }

    private static func assertTextRepresentation(
        _ clipboard: ClipboardStore,
        matches expected: Support.GenerationExpectation
    ) throws {
        let textRepresentation = MacClippyClipboardRepresentation(
            uti: Support.textRepresentationUTI,
            payloadBytes: Data(expected.textBody.utf8)
        )
        XCTAssertEqual(try clipboard.representations(for: expected.textRecordID), [textRepresentation])
    }

    private static func assertImageAttachment(
        _ storage: Storage,
        matches expected: Support.GenerationExpectation
    ) throws {
        guard case let .image(blobID, width, height) = try storage.clipboard.body(for: expected.imageRecordID) else {
            XCTFail("Expected an authenticated image record for generation \(expected.name).")
            return
        }
        XCTAssertEqual(blobID, expected.imageBlobID)
        XCTAssertEqual(width, 4)
        XCTAssertEqual(height, 3)
        XCTAssertEqual(try storage.blobs.read(id: expected.imageBlobID), expected.imagePayload)
        let representation = MacClippyClipboardRepresentation(
            uti: Support.imageRepresentationUTI,
            payloadBytes: nil,
            blobID: expected.representationBlobID
        )
        XCTAssertEqual(try storage.clipboard.representations(for: expected.imageRecordID), [representation])
        XCTAssertEqual(try storage.blobs.read(id: expected.representationBlobID), expected.representationPayload)
    }

    private static func assertSearch(
        _ search: SearchStore,
        matches expected: Support.GenerationExpectation
    ) throws {
        let allHits = try search.search(query: "phase5 \(expected.name)", limit: 8)
        XCTAssertEqual(Set(allHits.map(\.id)), expected.recordIDs)
        let textHits = try search.search(query: "authenticated", limit: 8)
        XCTAssertEqual(Set(textHits.map(\.id)), [expected.textRecordID])
        let imageHits = try search.search(query: "attachment", limit: 8)
        XCTAssertEqual(Set(imageHits.map(\.id)), [expected.imageRecordID])
        XCTAssertTrue(
            allHits.contains {
                $0.id == expected.textRecordID
                    && $0.snippet.contains("authenticated")
                    && $0.snippet.contains("clipboard")
            }
        )
        XCTAssertTrue(
            allHits.contains {
                $0.id == expected.imageRecordID
                    && $0.snippet.contains("searchable")
                    && $0.snippet.contains("attachment")
            }
        )
    }

    private static func assertCollections(
        _ storage: Storage,
        matches expected: Support.GenerationExpectation
    ) throws {
        let boards = try storage.pinboards.listStrict()
        XCTAssertEqual(boards.count, 1)
        XCTAssertEqual(boards.map(\.id), [expected.pinboardID])
        XCTAssertEqual(boards.first?.name, expected.pinboardName)
        XCTAssertEqual(boards.first?.itemIDs, [expected.textRecordID])

        let snippets = try storage.snippets.listStrict()
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets.map(\.id), [expected.snippetID])
        XCTAssertEqual(snippets.first?.name, expected.snippetName)
        XCTAssertEqual(snippets.first?.body, expected.snippetBody)
        XCTAssertEqual(snippets.first?.trigger, expected.snippetTrigger)
    }

    private static func assertMarkers(
        _ liveRootURL: URL,
        key: SymmetricKey,
        matches expected: Support.GenerationExpectation
    ) throws {
        for component in MacClippyBackup.liveComponents {
            let markerURL = liveRootURL.appendingPathComponent(component, isDirectory: true)
                .appendingPathComponent(Support.oldPayloadName)
            try assertMarker(markerURL, component: component, key: key, matches: expected)
        }
    }

    private static func assertMarker(
        _ markerURL: URL,
        component: String,
        key: SymmetricKey,
        matches expected: Support.GenerationExpectation
    ) throws {
        guard let expectedPayload = expected.markerPayloads[component] else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
            return
        }
        let envelope = try Data(contentsOf: markerURL)
        let payload = try MacClippyCipher.open(MacClippyEnvelope(combined: envelope), with: key)
        XCTAssertEqual(payload, expectedPayload, "Old component marker must survive rollback for \(component).")
    }

    private static func assertJournalAndTransactionArtifactsRemoved(_ liveRootURL: URL) {
        let rootChildren = (try? FileManager.default.contentsOfDirectory(atPath: liveRootURL.path)) ?? []
        XCTAssertFalse(rootChildren.contains(MacClippyBackup.restoreJournalFileName))
        XCTAssertFalse(rootChildren.contains { $0.hasPrefix(".macclippy-restore-") })
    }
}
