import CryptoKit
import Foundation
import GRDB
import MacClippyCore
import XCTest

final class MacClippyCoreTests: XCTestCase {
    func testCoreVersion() {
        XCTAssertEqual(MacClippyCore.version, "0.1.0")
    }

    func testCipherRoundTripAndWrongKey() throws {
        let key = SymmetricKey(size: .bits256)
        let envelope = try Cipher.seal(Data("secret".utf8), with: key)
        XCTAssertEqual(try Cipher.open(envelope, with: key), Data("secret".utf8))
        XCTAssertThrowsError(try Cipher.open(envelope, with: SymmetricKey(size: .bits256))) { error in
            XCTAssertEqual(error as? MacClippyCipherError, .openFailed)
        }
    }

    func testClipboardAppendListAndBody() throws {
        let store = try clipboardStore()
        let now = Date(timeIntervalSince1970: 10000)
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
            now: Date(timeIntervalSince1970: 20000)
        )
        _ = try store.append(
            .text("other app"),
            sourceAppBundleID: "com.example.Terminal",
            now: Date(timeIntervalSince1970: 20001)
        )
        try store.setCustomLabel(id: matching.id, label: "Project Alpha", now: Date(timeIntervalSince1970: 20000))
        try store.setOCRText(id: matching.id, text: "recognized")

        let filter = MacClippyClipboardMetadataFilter(
            sourceAppContains: ["editor"],
            labelContains: ["project"],
            requiresLabel: true,
            requiresOCR: true,
            modifiedBefore: [Date(timeIntervalSince1970: 20001)],
            modifiedAfter: [Date(timeIntervalSince1970: 19999)]
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

    func testClipboardBatchReadsChunkIDsAboveSQLiteVariableLimit() throws {
        let store = try clipboardStore()
        var records: [ClipboardItemMeta] = []
        records.reserveCapacity(1005)
        for index in 0 ..< 1005 {
            try records.append(store.append(.text("value-\(index)")))
        }

        let missing = RecordID.generate()
        let requestedIDs = [records[1004].id] + records.map(\.id) + [missing, records[0].id]

        let kinds = try store.contentKinds(for: requestedIDs)
        XCTAssertEqual(kinds.count, records.count)
        XCTAssertEqual(kinds[records[1004].id], .text)
        XCTAssertNil(kinds[missing])

        let metas = try store.metas(for: requestedIDs)
        XCTAssertEqual(metas.count, records.count + 2)
        XCTAssertEqual(metas.first?.id, records[1004].id)
        XCTAssertEqual(metas.last?.id, records[0].id)
        XCTAssertFalse(metas.contains(where: { $0.id == missing }))

        let bodies = try store.bodies(for: requestedIDs)
        XCTAssertEqual(bodies.count, records.count)
        XCTAssertEqual(bodies[records[0].id], .text("value-0"))
        XCTAssertEqual(bodies[records[1004].id], .text("value-1004"))
        XCTAssertNil(bodies[missing])
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
        XCTAssertEqual(
            try appliedMigrations(in: searchDatabase),
            ["001-search-core", "002-search-repair-state", "003-search-index-revision"]
        )

        let pinboardDatabase = try MacClippyDatabase(inMemory: true)
        _ = try PinboardStore(database: pinboardDatabase, deviceKey: testKey())
        XCTAssertEqual(try appliedMigrations(in: pinboardDatabase), ["001-pinboard-core"])

        let snippetDatabase = try MacClippyDatabase(inMemory: true)
        _ = try SnippetStore(database: snippetDatabase, deviceKey: testKey())
        XCTAssertEqual(try appliedMigrations(in: snippetDatabase), ["001-snippet-core"])
    }

    func testNewestOrderingUsesLamportTieBreak() throws {
        let store = try clipboardStore()
        let sameDate = Date(timeIntervalSince1970: 20000)
        let first = try store.append(.text("first"), now: sameDate)
        let second = try store.append(.text("second"), now: sameDate)

        let listed = try store.list(limit: 10)
        XCTAssertEqual(listed.map(\.id), [second.id, first.id])
        XCTAssertEqual(listed.map(\.lamport), [2, 1])
    }

    func testOldestCursorPaginatesAndFiltersWithoutDuplicates() throws {
        let store = try clipboardStore()
        let first = try store.append(.text("first"), now: Date(timeIntervalSince1970: 1))
        let image = try store.append(
            .image(blobID: "image", width: 1, height: 1),
            now: Date(timeIntervalSince1970: 2)
        )
        let last = try store.append(.text("last"), now: Date(timeIntervalSince1970: 3))

        let firstPage = try store.listOldest(limit: 1)
        XCTAssertEqual(firstPage.map(\.id), [first.id])
        let firstMeta = try XCTUnwrap(firstPage.last)
        let cursor = MacClippyClipboardHistoryCursor(
            modified: firstMeta.modified,
            lamport: firstMeta.lamport,
            id: firstMeta.id
        )
        let secondPage = try store.listOldest(limit: 2, after: cursor)
        XCTAssertEqual(secondPage.map(\.id), [image.id, last.id])

        let imagePage = try store.listOldest(limit: 10, contentKind: .image)
        XCTAssertEqual(imagePage.map(\.id), [image.id])
    }

    func testNegativePersistedLamportIsReportedAsCorruptStorage() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(database: database, deviceKey: testKey())
        let meta = try store.append(.text("corrupt lamport"))

        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET lamport = -1 WHERE id = ?",
                arguments: [meta.id.rawValue]
            )
        }

        XCTAssertThrowsError(try store.list(limit: 10)) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .invalidStoredRecord)
        }
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

    func testSearchIndexRevisionChangesOnlyWhenProjectionChanges() throws {
        let search = try searchStore()
        let id = RecordID.generate()

        XCTAssertEqual(try search.indexRevision(), 0)
        try search.insert(id: id, text: "first")
        let afterInsert = try search.indexRevision()
        XCTAssertEqual(afterInsert, 1)

        try search.upsert(id: id, text: "second")
        let afterUpsert = try search.indexRevision()
        XCTAssertEqual(afterUpsert, 2)

        try search.remove(id: id)
        XCTAssertEqual(try search.indexRevision(), 3)
        try search.remove(id: id)
        XCTAssertEqual(try search.indexRevision(), 3)
    }

    func testSearchKeysetCursorContinuesAfterRankAndRowID() throws {
        let search = try searchStore()
        for index in 0..<40 {
            try search.insert(id: RecordID.generate(), text: "keyset search \(index)")
        }

        let firstPage = try search.search(query: "keyset search", limit: 16)
        XCTAssertEqual(firstPage.count, 16)
        guard let last = firstPage.last else {
            XCTFail("expected a non-empty first page")
            return
        }

        let remaining = try search.search(
            query: "keyset search",
            limit: 40,
            after: MacClippySearchCursor(rank: last.rank, rowID: last.rowID)
        )
        XCTAssertEqual(remaining.count, 24)
        XCTAssertTrue(Set(firstPage.map(\.id)).isDisjoint(with: Set(remaining.map(\.id))))

        let complete = firstPage.map(\.id) + remaining.map(\.id)
        XCTAssertEqual(complete.count, 40)
        XCTAssertEqual(Set(complete).count, 40)
    }

    func testSearchSubstringFindsCJKInsideALongerToken() throws {
        let search = try searchStore()
        let matching = RecordID.generate()
        let other = RecordID.generate()
        try search.insert(id: matching, text: "你好世界")
        try search.insert(id: other, text: "unrelated english")

        let hits = try search.search(terms: ["世界"], limit: 10)
        XCTAssertEqual(hits.map(\.id), [matching])
        XCTAssertTrue(hits[0].snippet.contains("世界"))
    }

    func testSearchTermsKeepMultiWordPhrasesTogether() throws {
        let search = try searchStore()
        let matching = RecordID.generate()
        let split = RecordID.generate()
        try search.insert(id: matching, text: "project alpha notes")
        try search.insert(id: split, text: "project beta and alpha elsewhere")

        let hits = try search.search(terms: ["project alpha"], limit: 10)
        XCTAssertEqual(hits.map(\.id), [matching])
    }

    func testSearchPrefixStarMatchesTokenPrefix() throws {
        let search = try searchStore()
        let matching = RecordID.generate()
        try search.insert(id: matching, text: "clipboard manager")
        try search.insert(id: RecordID.generate(), text: "unrelated")

        XCTAssertEqual(try search.search(terms: ["clip*"], limit: 10).map(\.id), [matching])
    }

    func clipboardStore() throws -> ClipboardStore {
        try ClipboardStore(database: MacClippyDatabase(inMemory: true), deviceKey: testKey(), deviceID: XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")))
    }

    func searchStore() throws -> SearchStore {
        try SearchStore(database: MacClippyDatabase(inMemory: true))
    }

    func appliedMigrations(in database: MacClippyDatabase) throws -> [String] {
        try database.queue.read { connection in
            try String.fetchAll(connection, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    func testKey() -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 9, count: 32))
    }

    func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
