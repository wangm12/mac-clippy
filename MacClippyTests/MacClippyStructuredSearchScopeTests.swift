import Foundation
import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippyStructuredSearchScopeTests: XCTestCase {
    private var root: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyStructuredSearchScope-\(UUID().uuidString)", isDirectory: true)
        runtime = try MacClippyRuntime(paths: MacClippyPaths(rootURL: root))
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testCompositePagesPreserveFilteredResultsAcrossContinuations() throws {
        var expected = Set<RecordID>()
        for index in 0..<60 {
            let eligible = index % 3 == 0
            let record = try runtime.appendTestRecord(
                .text("common record \(index)"),
                sourceAppBundleID: eligible ? "com.example.scoped" : "com.example.other",
                now: Date(timeIntervalSince1970: Double(index + 1))
            )
            try runtime.searchStore.upsert(id: record.id, text: record.preview)
            if eligible { expected.insert(record.id) }
        }
        let first = try runtime.historyPage(limit: 16, query: "common app:scoped type:text")
        let cursor = try XCTUnwrap(first.nextPageToken)
        let second = try runtime.historyPage(limit: 16, query: "common app:scoped type:text", pageToken: cursor)
        let ids = first.items.map(\.id) + second.items.map(\.id)

        XCTAssertEqual(first.items.count, 16)
        XCTAssertEqual(second.items.count, 4)
        XCTAssertNil(second.nextPageToken)
        XCTAssertEqual(Set(ids), expected)
        XCTAssertEqual(ids.count, expected.count)
    }

    func testCompositeCJKAndURLFiltersUseTheSameScopeAsMetadataHistory() throws {
        let link = try runtime.appendTestRecord(.text("https://example.com/世界"))
        let text = try runtime.appendTestRecord(.text("你好世界"))
        try runtime.searchStore.upsert(id: link.id, text: link.preview)
        try runtime.searchStore.upsert(id: text.id, text: text.preview)

        XCTAssertEqual(try runtime.historyPage(limit: 16, query: "世界 type:url").items.map(\.id), [link.id])
        XCTAssertTrue(try runtime.historyPage(limit: 16, query: "世界 type:image").items.isEmpty)
        XCTAssertTrue(try runtime.historyPage(limit: 16, query: "世界 app:missing").items.isEmpty)
    }

    func testCancelledScopeBuildReturnsNoPartialSearchResults() throws {
        let record = try runtime.appendTestRecord(.text("common text"))
        try runtime.searchStore.upsert(id: record.id, text: record.preview)
        var checks = 0
        let page = try runtime.historyPage(limit: 16, query: "common type:text") {
            checks += 1
            return checks >= 3
        }
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextPageToken)
    }

    func testCompositeScopePreservesUnicodeAndLegacyAppNameMatching() throws {
        let bundleID = "com.example.revieweditor"
        MacClippySourceAppResolver.testDisplayNames[bundleID] = "ÉDITEUR"
        defer { MacClippySourceAppResolver.testDisplayNames.removeValue(forKey: bundleID) }
        let record = try runtime.clipboardStore.append(
            .text("common legacy text"), sourceAppBundleID: bundleID, sourceAppDisplayName: nil
        )
        _ = try runtime.setCustomLabel(id: record.id, label: "ÉQUIPE")

        XCTAssertEqual(try runtime.historyPage(limit: 16, query: "common app:éditeur").items.map(\.id), [record.id])
        XCTAssertEqual(try runtime.historyPage(limit: 16, query: "common label:équipe").items.map(\.id), [record.id])
    }

    func testCompositeURLWhitespaceMatchesStructuredHistoryAndSelection() throws {
        var expected = Set<RecordID>()
        for whitespace in ["", " ", "\t", "\n", "\u{00A0}", "\u{3000}"] {
            let text = whitespace + "https://example.com/世界" + whitespace
            let record = try runtime.appendTestRecord(.text(text))
            try runtime.searchStore.upsert(id: record.id, text: text)
            expected.insert(record.id)
        }
        XCTAssertEqual(Set(try runtime.historyPage(limit: 16, query: "世界 type:url").items.map(\.id)), expected)
        XCTAssertEqual(Set(try runtime.historyPage(limit: 16, query: "type:url").items.map(\.id)), expected)
        XCTAssertEqual(Set(try runtime.historyRecordIDs(query: "世界 type:url")), expected)
    }

    func testCompositeContinuationReusesImmutableScopeAndRejectsMetadataChanges() throws {
        try seedCommonRecords(40)
        let first = try runtime.historyPage(limit: 16, query: "common type:text")
        let firstToken = try XCTUnwrap(first.nextPageToken)
        let firstScope = try XCTUnwrap(firstToken.searchCursor?.structuredScope)
        let second = try runtime.historyPage(limit: 16, query: "common type:text", pageToken: firstToken)
        let secondToken = try XCTUnwrap(second.nextPageToken)
        XCTAssertTrue(try XCTUnwrap(secondToken.searchCursor?.structuredScope) === firstScope)
        let indexRevision = try runtime.searchStore.indexRevision()
        _ = try runtime.clipboardStore.setCustomLabel(id: first.items[0].id, label: "metadata-only mutation")
        XCTAssertEqual(try runtime.searchStore.indexRevision(), indexRevision)
        XCTAssertThrowsError(try runtime.historyPage(limit: 16, query: "common type:text", pageToken: secondToken)) {
            XCTAssertEqual($0 as? MacClippyHistoryPageError, .searchIndexChanged)
        }
    }

    func testCompositeContinuationRejectsDifferentQuery() throws {
        try seedCommonRecords(20)
        let first = try runtime.historyPage(limit: 16, query: "common type:text")
        let token = try XCTUnwrap(first.nextPageToken)
        XCTAssertThrowsError(try runtime.historyPage(limit: 16, query: "other type:text", pageToken: token)) {
            XCTAssertEqual($0 as? MacClippyHistoryPageError, .searchIndexChanged)
        }
    }

    func testAppContinuationInvalidatesWhenLegacyResolvedMembershipChanges() throws {
        let firstBundle = "com.example.scopefirst"
        let secondBundle = "com.example.scopesecond"
        MacClippySourceAppResolver.testDisplayNames[firstBundle] = "Review app"
        MacClippySourceAppResolver.testDisplayNames[secondBundle] = "Hidden app"
        defer {
            MacClippySourceAppResolver.testDisplayNames.removeValue(forKey: firstBundle)
            MacClippySourceAppResolver.testDisplayNames.removeValue(forKey: secondBundle)
        }
        for _ in 0..<40 {
            let meta = try runtime.clipboardStore.append(.text("common body"), sourceAppBundleID: firstBundle)
            try runtime.searchStore.upsert(id: meta.id, text: "common body")
        }
        let newlyEligible = try runtime.clipboardStore.append(.text("common body"), sourceAppBundleID: secondBundle)
        try runtime.searchStore.upsert(id: newlyEligible.id, text: "common body")
        let first = try runtime.historyPage(limit: 16, query: "common app:review")
        let firstToken = try XCTUnwrap(first.nextPageToken)
        MacClippySourceAppResolver.testDisplayNames[secondBundle] = "Review app"
        XCTAssertThrowsError(try runtime.historyPage(limit: 16, query: "common app:review", pageToken: firstToken)) {
            XCTAssertEqual($0 as? MacClippyHistoryPageError, .searchIndexChanged)
        }
        let restarted = try runtime.historyRecordIDs(query: "common app:review")
        XCTAssertEqual(restarted.count, 41)
        XCTAssertTrue(restarted.contains(newlyEligible.id))
    }

    private func seedCommonRecords(_ count: Int) throws {
        for _ in 0..<count {
            let meta = try runtime.appendTestRecord(.text("common body"))
            try runtime.searchStore.upsert(id: meta.id, text: "common body")
        }
    }
}
