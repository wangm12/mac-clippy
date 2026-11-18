import XCTest

import MacClippyCore

final class MacClippySearchStoreBehaviorTests: XCTestCase {
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
        XCTAssertEqual(try search.sourceProjectionVersion(), 0)
        try search.setSourceProjectionVersion(SearchStore.currentSourceProjectionVersion)
        XCTAssertEqual(try search.sourceProjectionVersion(), SearchStore.currentSourceProjectionVersion)
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

    func testSearchTermsFindASCIIInfixInsideAToken() throws {
        let search = try searchStore()
        let matching = RecordID.generate()
        try search.insert(id: matching, text: "renew the passport")
        try search.insert(id: RecordID.generate(), text: "unrelated note")

        XCTAssertEqual(try search.search(terms: ["ss"], limit: 10).map(\.id), [matching])
    }

    func testSearchTermsPreferPrefixHitsBeforeInfix() throws {
        let search = try searchStore()
        let prefix = RecordID.generate()
        let infix = RecordID.generate()
        try search.insert(id: prefix, text: "ssl certificate")
        try search.insert(id: infix, text: "renew the passport")

        XCTAssertEqual(try search.search(terms: ["ss"], limit: 10).map(\.id), [prefix, infix])
    }

    func testSearchTermsRequireEveryWordOnPrefixOrInfix() throws {
        let search = try searchStore()
        let both = RecordID.generate()
        try search.insert(id: both, text: "renew the passport")
        try search.insert(id: RecordID.generate(), text: "the past event")
        try search.insert(id: RecordID.generate(), text: "harbor seaport")

        XCTAssertEqual(try search.search(terms: ["pas", "port"], limit: 10).map(\.id), [both])
    }

    func testSearchTermsPagePrefixHitsBeforeInfixWithoutRepeats() throws {
        let search = try searchStore()
        var prefixIDs: [RecordID] = []
        for index in 0..<3 {
            let id = RecordID.generate()
            prefixIDs.append(id)
            try search.insert(id: id, text: "ssl token \(index)")
        }
        let infix = RecordID.generate()
        try search.insert(id: infix, text: "renew the passport")

        let first = try search.search(terms: ["ss"], limit: 2)
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(Set(first.map(\.id)).isSubset(of: Set(prefixIDs)))
        guard let last = first.last else {
            return XCTFail("expected a prefix page")
        }

        let rest = try search.search(
            terms: ["ss"],
            limit: 8,
            after: MacClippySearchCursor(rank: last.rank, rowID: last.rowID)
        )
        let complete = first.map(\.id) + rest.map(\.id)
        XCTAssertEqual(Set(complete).count, complete.count)
        XCTAssertEqual(Set(complete), Set(prefixIDs + [infix]))
        XCTAssertEqual(complete.last, infix)
    }

    func testSearchTermsKeepPhrasesAndDottedNamesOffInfix() throws {
        let search = try searchStore()
        let phrase = RecordID.generate()
        let dotted = RecordID.generate()
        try search.insert(id: phrase, text: "project alpha notes")
        try search.insert(id: RecordID.generate(), text: "xxproject alphayy")
        try search.insert(id: dotted, text: "invoice.pdf")
        try search.insert(id: RecordID.generate(), text: "fooinvoice.pdfbar")

        XCTAssertEqual(try search.search(terms: ["project alpha"], limit: 10).map(\.id), [phrase])
        XCTAssertEqual(try search.search(terms: ["invoice.pdf"], limit: 10).map(\.id), [dotted])
    }

    private func searchStore() throws -> SearchStore {
        try SearchStore(database: MacClippyDatabase(inMemory: true))
    }
}
