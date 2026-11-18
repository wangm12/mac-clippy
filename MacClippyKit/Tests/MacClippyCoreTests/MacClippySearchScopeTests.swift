import CryptoKit
import GRDB
import XCTest

import MacClippyCore

final class MacClippySearchScopeTests: XCTestCase {
    func testScopedSearchPagesPrefixThenInfixWithoutRepeatingOrLeakingRecords() throws {
        let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
        let prefixIDs = (0..<3).map { _ in RecordID.generate() }
        for id in prefixIDs { try search.upsert(id: id, text: "ssl certificate") }
        let infixID = RecordID.generate()
        try search.upsert(id: infixID, text: "renew passport")
        let excludedID = RecordID.generate()
        try search.upsert(id: excludedID, text: "ssl certificate")
        let scope = prefixIDs + [infixID]
        let revision = try search.indexRevision()
        var cursor: MacClippySearchCursor?
        var hits: [SearchHit] = []
        while true {
            let page = try search.search(terms: ["ss"], limit: 2, after: cursor, matchingRecordIDs: scope)
            guard let last = page.last else { break }
            hits += page
            cursor = MacClippySearchCursor(rank: last.rank, rowID: last.rowID)
        }

        XCTAssertEqual(Set(hits.map(\.id)), Set(scope))
        XCTAssertEqual(hits.count, scope.count)
        XCTAssertEqual(hits.last?.id, infixID)
        XCTAssertEqual(try search.indexRevision(), revision)
        XCTAssertEqual(try search.search(terms: ["ss"], limit: 10).count, 5)
        XCTAssertTrue(try search.search(terms: ["ss"], limit: 10, matchingRecordIDs: []).isEmpty)
    }

    func testScopedSearchRetainsCJKAndPhraseSemanticsAndReplacesPreviousScope() throws {
        let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
        let first = RecordID.generate()
        let second = RecordID.generate()
        try search.upsert(id: first, text: "你好世界 project alpha notes")
        try search.upsert(id: second, text: "你好世界 project beta and alpha")

        XCTAssertEqual(try search.search(terms: ["世界"], limit: 10, matchingRecordIDs: [first]).map(\.id), [first])
        XCTAssertEqual(try search.search(terms: ["世界"], limit: 10, matchingRecordIDs: [second]).map(\.id), [second])
        XCTAssertTrue(try search.search(terms: ["project alpha"], limit: 10, matchingRecordIDs: [second]).isEmpty)
        XCTAssertEqual(
            try search.search(terms: ["project alpha"], limit: 10, matchingRecordIDs: [first]).map(\.id), [first]
        )
    }

    func testScopedSearchSupportsMoreThanSQLiteVariableLimitAndDuplicateIDs() throws {
        let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
        let ids = (0..<1_025).map { _ in RecordID.generate() }
        for id in ids { try search.upsert(id: id, text: "common record") }
        try search.upsert(id: RecordID.generate(), text: "common record")
        let hits = try search.search(terms: ["common"], limit: 2_000, matchingRecordIDs: ids + ids)
        XCTAssertEqual(Set(hits.map(\.id)), Set(ids))
        XCTAssertEqual(hits.count, ids.count)
    }

    func testBroadScopedFTSSearchAtTenThousandRecordsDoesNotRestartMatchPerRow() throws {
        let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
        let ids = (0..<10_000).map { _ in RecordID.generate() }
        for (index, id) in ids.enumerated() {
            try search.upsert(id: id, text: "common body marker\(index)")
        }
        let start = Date()
        let hits = try search.search(terms: ["common"], limit: 128, matchingRecordIDs: ids)

        XCTAssertEqual(hits.count, 128)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "scope must preserve a single FTS MATCH scan")
    }

    func testReusableScopeDoesNotRewriteTEMPTableAndSurvivesInterleavedScopes() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let search = try SearchStore(database: database)
        let ids = (0..<6).map { _ in RecordID.generate() }
        for id in ids { try search.upsert(id: id, text: "common body") }
        let scope = MacClippySearchRecordScope(recordIDs: Array(ids.prefix(5)))
        let first = try search.searchScoped(terms: ["common"], limit: 2, scope: scope)
        let changes = try database.queue.read { try Int.fetchOne($0, sql: "SELECT total_changes()") }
        let last = try XCTUnwrap(first.last)
        let cursor = MacClippySearchCursor(rank: last.rank, rowID: last.rowID)
        let second = try search.searchScoped(terms: ["common"], limit: 10, after: cursor, scope: scope)
        XCTAssertEqual(Set((first + second).map(\.id)), Set(ids.prefix(5)))
        let changesAfterContinuation = try database.queue.read { try Int.fetchOne($0, sql: "SELECT total_changes()") }
        XCTAssertEqual(changesAfterContinuation, changes)

        let other = MacClippySearchRecordScope(recordIDs: [ids[5]])
        XCTAssertEqual(try search.searchScoped(terms: ["common"], limit: 10, scope: other).map(\.id), [ids[5]])
        let restored = try search.searchScoped(terms: ["common"], limit: 10, scope: scope)
        XCTAssertEqual(Set(restored.map(\.id)), Set(ids.prefix(5)))
        XCTAssertEqual(try search.search(terms: ["common"], limit: 10).count, 6)
    }

    func testKindScopePaginationUsesCoveringIDRangeAndPreservesEveryRecord() throws {
        let database = try MacClippyDatabase(inMemory: true)
        let store = try ClipboardStore(
            database: database, deviceKey: SymmetricKey(data: Data(repeating: 39, count: 32))
        )
        let ids = try (0..<1_025).map { try store.append(.text("scope body \($0)")).id }
        _ = try store.append(.files([URL(fileURLWithPath: "/tmp/scoped-file")]))
        var collected: [RecordID] = []
        var after: RecordID?
        while true {
            let page = try store.matchingRecordIDs(filter: .init(contentKind: .text), afterID: after)
            collected += page
            guard page.count == 512, let last = page.last else { break }
            after = last
        }
        XCTAssertEqual(collected.map(\.rawValue), ids.map(\.rawValue).sorted())
        let plan = try database.queue.read { connection in
            try Row.fetchAll(
                connection,
                sql: """
                    EXPLAIN QUERY PLAN SELECT id FROM clipboard_records
                    WHERE content_kind = ? AND id > ? ORDER BY id LIMIT 512
                    """,
                arguments: ["text", ids[0].rawValue]
            ).map { $0["detail"] as String }
        }
        XCTAssertTrue(plan.contains { $0.contains("COVERING INDEX idx_macclippy_records_content_kind_id") })
        XCTAssertTrue(plan.contains { $0.contains("id>?") })
        XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") }, "ID keyset pages must not re-sort the whole kind")
    }

    func testReusableScopeWorksOnReadOnlyDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyReadOnlyScope-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("search.sqlite")
        let writer = try MacClippyDatabase(url: url)
        let writableSearch = try SearchStore(database: writer)
        let id = RecordID.generate()
        try writableSearch.upsert(id: id, text: "readonly scope")
        try writer.queue.close()
        let reader = try MacClippyDatabase(url: url, readOnly: true)
        let search = try SearchStore(database: reader)
        let scope = MacClippySearchRecordScope(recordIDs: [id])
        XCTAssertEqual(try search.searchScoped(terms: ["readonly"], limit: 10, scope: scope).map(\.id), [id])
        XCTAssertEqual(try search.searchScoped(terms: ["readonly"], limit: 10, scope: scope).map(\.id), [id])
        try reader.queue.close()
    }
}
