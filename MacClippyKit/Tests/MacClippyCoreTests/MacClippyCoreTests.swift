import CryptoKit
import Foundation
import XCTest

import GRDB
import MacClippyCore

final class MacClippyCoreTests: XCTestCase {
    func testCoreVersion() {
        XCTAssertEqual(MacClippyCore.version, "0.1.0")
    }

    func testCipherRoundTripAndWrongKey() throws {
        let key = SymmetricKey(size: .bits256)
        let envelope = try Cipher.seal(Data("secret".utf8), with: key)
        XCTAssertEqual(try Cipher.open(envelope, with: key), Data("secret".utf8))
        XCTAssertThrowsError(try Cipher.open(envelope, with: SymmetricKey(size: .bits256)))
    }

    func testClipboardAppendListAndBody() throws {
        let store = try clipboardStore()
        let now = Date(timeIntervalSince1970: 10_000)
        let meta = try store.append(.text("hello world"), sourceAppBundleID: "com.example.Editor", detectedTypeJSON: "{\"type\":\"plain\"}", now: now)

        XCTAssertEqual(try store.list(limit: 10), [meta])
        XCTAssertEqual(try store.body(for: meta.id), .text("hello world"))
        XCTAssertEqual(try store.list(limit: 10)[0].sourceAppBundleID, "com.example.Editor")
    }

    func testClipboardMetadataFilterPushesStructuredPredicatesIntoStoreQuery() throws {
        let store = try clipboardStore()
        let matching = try store.append(
            .text("matching"),
            sourceAppBundleID: "com.example.Editor",
            now: Date(timeIntervalSince1970: 20_000)
        )
        _ = try store.append(
            .text("other app"),
            sourceAppBundleID: "com.example.Terminal",
            now: Date(timeIntervalSince1970: 20_001)
        )
        try store.setCustomLabel(id: matching.id, label: "Project Alpha", now: Date(timeIntervalSince1970: 20_000))
        try store.setOCRText(id: matching.id, text: "recognized")

        let filter = MacClippyClipboardMetadataFilter(
            sourceAppContains: ["editor"],
            labelContains: ["project"],
            requiresLabel: true,
            requiresOCR: true,
            modifiedBefore: [Date(timeIntervalSince1970: 20_001)],
            modifiedAfter: [Date(timeIntervalSince1970: 19_999)]
        )
        XCTAssertEqual(try store.list(limit: 10, filter: filter).map(\.id), [matching.id])
    }

    func testClipboardBatchBodiesPreserveRequestedRecordsAndSkipMissingIDs() throws {
        let store = try clipboardStore()
        let first = try store.append(.text("first"))
        let second = try store.append(.text("second"))
        let missing = RecordID.generate()

        let bodies = try store.bodies(for: [second.id, missing, first.id])

        XCTAssertEqual(bodies[second.id], .text("second"))
        XCTAssertEqual(bodies[first.id], .text("first"))
        XCTAssertNil(bodies[missing])
        XCTAssertEqual(bodies.count, 2)
    }

    func testStoreInitializersApplyDeclaredMigrations() throws {
        let clipboardDatabase = try MacClippyDatabase(inMemory: true)
        _ = try ClipboardStore(database: clipboardDatabase, deviceKey: testKey())
        XCTAssertEqual(
            try appliedMigrations(in: clipboardDatabase),
            ["001-clipboard-core", "002-clipboard-representations", "003-clipboard-query-indexes", "004-deletion-journal", "005-deletion-records"]
        )

        let searchDatabase = try MacClippyDatabase(inMemory: true)
        _ = try SearchStore(database: searchDatabase)
        XCTAssertEqual(try appliedMigrations(in: searchDatabase), ["001-search-core", "002-search-repair-state"])

        let pinboardDatabase = try MacClippyDatabase(inMemory: true)
        _ = try PinboardStore(database: pinboardDatabase, deviceKey: testKey())
        XCTAssertEqual(try appliedMigrations(in: pinboardDatabase), ["001-pinboard-core"])

        let snippetDatabase = try MacClippyDatabase(inMemory: true)
        _ = try SnippetStore(database: snippetDatabase, deviceKey: testKey())
        XCTAssertEqual(try appliedMigrations(in: snippetDatabase), ["001-snippet-core"])
    }

    func testNewestOrderingUsesLamportTieBreak() throws {
        let store = try clipboardStore()
        let sameDate = Date(timeIntervalSince1970: 20_000)
        let first = try store.append(.text("first"), now: sameDate)
        let second = try store.append(.text("second"), now: sameDate)

        let listed = try store.list(limit: 10)
        XCTAssertEqual(listed.map(\.id), [second.id, first.id])
        XCTAssertEqual(listed.map(\.lamport), [2, 1])
    }

    func testSearchInsertAndRemoveEscapesQuery() throws {
        let search = try searchStore()
        let first = RecordID.generate()
        let second = RecordID.generate()
        try search.insert(id: first, text: "hello \"quoted\" clipboard")
        try search.insert(id: second, text: "unrelated note")

        XCTAssertEqual(try search.search(query: "hello \"quoted\"", limit: 10).map(\.id), [first])
        try search.remove(id: first)
        XCTAssertTrue(try search.search(query: "hello", limit: 10).isEmpty)
    }

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

        XCTAssertFalse(blobs.contains(id: blobID))
        XCTAssertThrowsError(try store.body(for: meta.id))
        XCTAssertTrue(try search.search(query: "image", limit: 10).isEmpty)
    }

    func testPinboardItemsAreProtectedFromRetention() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let protected = try store.append(.text("protected"), now: Date(timeIntervalSince1970: 1))
        let removable = try store.append(.text("removable"), now: Date(timeIntervalSince1970: 2))
        let pinboards = try PinboardStore(database: try MacClippyDatabase(inMemory: true), deviceKey: testKey())
        let board = try pinboards.create(name: "Keep")
        try pinboards.addItem(protected.id, to: board.id)

        try RetentionPolicy(maxItems: 0).enforce(store: store, blobs: blobs, search: search, pinboards: pinboards)

        XCTAssertEqual(try store.body(for: protected.id), .text("protected"))
        XCTAssertThrowsError(try store.body(for: removable.id))
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
        XCTAssertTrue(blobs.contains(id: blobID))
    }

    func testMaxAgeAndImageByteRetention() throws {
        let store = try clipboardStore()
        let search = try searchStore()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(rootURL: root, key: testKey())
        let old = try store.append(.text("old"), now: Date(timeIntervalSince1970: 1))
        let imageBlob = try blobs.write(Data(repeating: 3, count: 100))
        let image = try store.append(.image(blobID: imageBlob, width: 1, height: 1), now: Date(timeIntervalSince1970: 2))
        let imageRecordBlob = try blobs.write(Data(repeating: 4, count: 100))
        let newestImage = try store.append(.image(blobID: imageRecordBlob, width: 1, height: 1), now: Date(timeIntervalSince1970: 3))

        try RetentionPolicy(maxAgeSeconds: 5, maxImageBytes: blobs.byteSize(id: imageRecordBlob)).enforce(
            store: store, blobs: blobs, search: search, now: Date(timeIntervalSince1970: 7)
        )

        XCTAssertThrowsError(try store.body(for: old.id))
        XCTAssertThrowsError(try store.body(for: image.id))
        XCTAssertEqual(try store.body(for: newestImage.id), .image(blobID: imageRecordBlob, width: 1, height: 1))
        XCTAssertFalse(blobs.contains(id: imageBlob))
    }

    func testRegexAndCaptureExclusionRules() throws {
        let blocklist = try RegexBlocklist(patterns: ["password\\s*="])
        XCTAssertTrue(blocklist.matches("password = secret"))
        XCTAssertFalse(blocklist.matches("username = user"))
        XCTAssertThrowsError(try RegexBlocklist(patterns: ["["]))

        // Production default: sensitive pasteboard markers and common
        // password-manager apps are excluded. Capture All is explicit and
        // does not bypass an app exclusion.
        let safeRules = CaptureExclusionRules(excludedAppBundleIDs: ["com.Example.Passwords"])
        XCTAssertTrue(safeRules.shouldExclude(appBundleID: "com.example.passwords", pasteboardTypes: []))
        XCTAssertTrue(safeRules.shouldExclude(appBundleID: nil, pasteboardTypes: ["org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(safeRules.shouldExclude(appBundleID: nil, pasteboardTypes: ["org.nspasteboard.TransientType"]))
        XCTAssertTrue(safeRules.shouldExclude(appBundleID: nil, pasteboardTypes: ["org.nspasteboard.AutoGeneratedType"]))
        XCTAssertFalse(safeRules.shouldExclude(appBundleID: "com.example.editor", pasteboardTypes: ["public.utf8-plain-text"]))
        let privacyRules = CaptureExclusionRules(excludedTextPatterns: ["token\\s*="])
        XCTAssertTrue(privacyRules.shouldExcludeText("token = secret"))
        XCTAssertFalse(privacyRules.shouldExcludeText("username = user"))
        let legacyRules = CaptureExclusionRules.legacyDefault()
        XCTAssertTrue(legacyRules.shouldExclude(appBundleID: nil, pasteboardTypes: ["org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(legacyRules.shouldExclude(appBundleID: nil, pasteboardTypes: ["org.nspasteboard.TransientType"]))
        XCTAssertFalse(legacyRules.shouldExclude(appBundleID: "com.example.editor", pasteboardTypes: ["public.utf8-plain-text"]))

        let captureAllRules = CaptureExclusionRules(captureAll: true)
        XCTAssertFalse(captureAllRules.shouldExclude(appBundleID: nil, pasteboardTypes: ["com.unknown.custom", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(captureAllRules.shouldExclude(appBundleID: "com.agilebits.onepassword7", pasteboardTypes: []))
    }

    func testSmartTextDetectionAndTransforms() throws {
        XCTAssertEqual(SmartTextService.detect("https://example.com/a"), .url)
        XCTAssertEqual(SmartTextService.detect("person@example.com"), .email)
        XCTAssertEqual(SmartTextService.detect("#ff00aa"), .color)
        XCTAssertEqual(SmartTextService.detect("SELECT * FROM users"), .code(language: .sql))

        let cleaned = try XCTUnwrap(SmartTextService.cleanTrackingParameters("https://example.com?a=1&utm_source=test&gclid=x"))
        XCTAssertEqual(cleaned.cleaned, "https://example.com?a=1")
        XCTAssertEqual(cleaned.removedCount, 2)
        XCTAssertEqual(TextTransform.uppercase.apply(to: "hello"), "HELLO")
        XCTAssertEqual(TextTransform.trim.apply(to: "  hello \n"), "hello")
        XCTAssertEqual(TextTransform.prettyJSON.apply(to: "{\"b\":2,\"a\":1}"), "{\n  \"a\" : 1,\n  \"b\" : 2\n}")
        XCTAssertEqual(TextTransform.cleanTrackingURL.apply(to: "https://example.com?utm_medium=x"), "https://example.com")
    }

    func testTextTransformDisplayNameIsNonEmptyAndStable() throws {
        // Every transform case must map to a non-empty human-readable label
        // so the dock Transform submenu never shows a blank item, and the
        // labels must match the user-facing names chosen for the feature.
        let expected: [TextTransform: String] = [
            .uppercase: "Uppercase",
            .lowercase: "Lowercase",
            .trim: "Trim whitespace",
            .prettyJSON: "Pretty JSON",
            .cleanTrackingURL: "Clean tracking URL"
        ]
        for transform in TextTransform.allCases {
            let name = transform.displayName
            XCTAssertFalse(name.isEmpty, "\(transform.rawValue) must have a non-empty displayName")
            XCTAssertEqual(name, expected[transform], "\(transform.rawValue) displayName changed")
        }
        // The label set must stay in sync with CaseIterable so a future case
        // is not silently missing a label.
        XCTAssertEqual(TextTransform.allCases.count, expected.count)
    }

    func testCategoryColorUsesExplicitColorOrDeterministicFallback() throws {
        let id = try XCTUnwrap(RecordID(rawValue: "0123456789ABCDEFGHJKMNPQRS"))
        let board = Pinboard(id: id, name: "Work")

        XCTAssertEqual(MacClippyCategoryColorPolicy.color(for: board), MacClippyCategoryColorPolicy.color(for: board))
        XCTAssertEqual(
            MacClippyCategoryColorPolicy.color(for: Pinboard(id: id, name: "Work", color: "#123456")),
            "#123456"
        )
        XCTAssertEqual(
            MacClippyCategoryColorPolicy.color(for: Pinboard(id: id, name: "Work", color: "  ")),
            MacClippyCategoryColorPolicy.color(for: board)
        )
    }

    func testClipboardDropPolicyParsesIDsAndTreatsDuplicatesAsSafeNoOp() throws {
        let id = try XCTUnwrap(RecordID(rawValue: "0123456789ABCDEFGHJKMNPQRS"))

        XCTAssertEqual(MacClippyClipboardDropPolicy.recordID(from: "  \(id.rawValue)\n"), id)
        XCTAssertEqual(MacClippyClipboardDropPolicy.decision(for: id.rawValue, existingIDs: []), .accept)
        XCTAssertEqual(MacClippyClipboardDropPolicy.decision(for: id.rawValue, existingIDs: [id]), .duplicate)
        XCTAssertEqual(MacClippyClipboardDropPolicy.decision(for: "invalid", existingIDs: []), .invalid)
    }

    func testDeviceKeyUsesInjectedKeychain() throws {
        let keychain = InMemoryKeychain()
        let first = try MacClippyDeviceKey(keychain: keychain).deviceKey()
        let second = try MacClippyDeviceKey(keychain: keychain).deviceKey()
        XCTAssertEqual(first.withUnsafeBytes { Data($0) }, second.withUnsafeBytes { Data($0) })
        XCTAssertEqual(MacClippySystemKeychain.service, "com.macallyouneed.macclippy.device-key")
    }

    private func clipboardStore() throws -> ClipboardStore {
        try ClipboardStore(database: MacClippyDatabase(inMemory: true), deviceKey: testKey(), deviceID: XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")))
    }

    private func searchStore() throws -> SearchStore {
        try SearchStore(database: MacClippyDatabase(inMemory: true))
    }

    private func appliedMigrations(in database: MacClippyDatabase) throws -> [String] {
        try database.queue.read { connection in
            try String.fetchAll(connection, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    private func testKey() -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 9, count: 32))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
