import CryptoKit
import XCTest

import MacClippyCore

final class MacClippySearchURLGrammarTests: XCTestCase {
    func testTypeURLParsesAsURLClause() {
        let parsed = MacClippySearchGrammar.parse("type:url")
        XCTAssertEqual(parsed.clauses, [.url])
        XCTAssertTrue(parsed.bareTerms.isEmpty)
        XCTAssertTrue(parsed.isStructuredOnly)
    }

    func testPredicateURLUsesSearchRecordFlag() {
        let matching = MacClippySearchGrammar.SearchRecord(
            contentKind: .text,
            sourceAppBundleID: nil,
            customLabel: nil,
            ocrText: nil,
            modified: Date(timeIntervalSince1970: 1_783_728_000),
            isURL: true
        )
        let other = MacClippySearchGrammar.SearchRecord(
            contentKind: .text,
            sourceAppBundleID: nil,
            customLabel: nil,
            ocrText: nil,
            modified: Date(timeIntervalSince1970: 1_783_728_000),
            isURL: false
        )
        XCTAssertTrue(MacClippySearchGrammar.matches(.url, record: matching))
        XCTAssertFalse(MacClippySearchGrammar.matches(.url, record: other))
    }

    func testConflictingContentTypesAreDetected() {
        XCTAssertTrue(MacClippySearchGrammar.parse("type:text type:image").hasConflictingContentTypes)
        XCTAssertTrue(MacClippySearchGrammar.parse("type:url type:image").hasConflictingContentTypes)
        XCTAssertFalse(MacClippySearchGrammar.parse("type:url type:text").hasConflictingContentTypes)
        XCTAssertFalse(MacClippySearchGrammar.parse("type:text").hasConflictingContentTypes)
    }

    func testListRequiresURLMatchesSingleURLPreview() throws {
        let store = try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: SymmetricKey(data: Data(repeating: 9, count: 32)),
            deviceID: XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
        let url = try store.append(.text("https://example.com/macclippy"))
        _ = try store.append(.text("just a sentence"))
        let www = try store.append(.text("www.example.com"))
        _ = try store.append(.text("http status 500"))
        XCTAssertEqual(try store.list(limit: 10, requiresURL: true).map(\.id), [www.id, url.id])
        XCTAssertTrue(MacClippySmartText.matchesURL("https://example.com/macclippy"))
        XCTAssertTrue(MacClippySmartText.matchesURL("www.example.com"))
        XCTAssertFalse(MacClippySmartText.matchesURL("http status 500"))
    }

    func testURLScopeAndListMatchGrammarForSurroundingUnicodeWhitespace() throws {
        let store = try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: SymmetricKey(data: Data(repeating: 17, count: 32))
        )
        var expected = Set<RecordID>()
        for whitespace in ["", " ", "\t", "\n", "\r\n", "\u{00A0}", "\u{3000}"] {
            let meta = try store.append(.text(whitespace + "https://example.com/世界" + whitespace))
            XCTAssertTrue(MacClippySearchGrammar.matches(
                .url, record: .init(meta: meta, contentKind: .text)
            ))
            expected.insert(meta.id)
        }
        for text in ["https://example.com has a sentence", "www.example.com has a sentence"] {
            let meta = try store.append(.text(text))
            XCTAssertFalse(MacClippySearchGrammar.matches(.url, record: .init(meta: meta, contentKind: .text)))
        }
        XCTAssertEqual(Set(try store.list(limit: 100, requiresURL: true).map(\.id)), expected)
        XCTAssertEqual(
            Set(try store.matchingRecordIDs(filter: .init(), requiresURL: true)), expected
        )
    }
}
