import XCTest

@testable import MacClippyCore

final class MacClippySmartListPolicyTests: XCTestCase {
    func testCatalogCoversURLAndImage() {
        XCTAssertEqual(MacClippySmartListPolicy.catalog.map(\.id), ["urls", "images"])
        XCTAssertEqual(MacClippySmartListPolicy.catalog.map(\.title), ["URL", "Image"])
        XCTAssertEqual(
            MacClippySearchGrammar.parse(MacClippySmartListPolicy.catalog[0].query).clauses,
            [.url]
        )
        XCTAssertEqual(
            MacClippySearchGrammar.parse(MacClippySmartListPolicy.catalog[1].query).clauses,
            [.type(.image)]
        )
    }

    func testApplyTogglesListAndKeepsBareTerms() {
        let urls = MacClippySmartListPolicy.catalog[0]
        let next = MacClippySmartListPolicy.apply(urls, to: "invoice")
        XCTAssertEqual(MacClippySearchGrammar.parse(next).bareTerms, ["invoice"])
        XCTAssertEqual(MacClippySearchGrammar.parse(next).clauses, [.url])
        XCTAssertTrue(MacClippySmartListPolicy.isActive(urls, in: next))

        let cleared = MacClippySmartListPolicy.apply(urls, to: next)
        XCTAssertEqual(MacClippySearchGrammar.parse(cleared).bareTerms, ["invoice"])
        XCTAssertFalse(MacClippySearchGrammar.parse(cleared).hasStructuredClauses)
        XCTAssertFalse(MacClippySmartListPolicy.isActive(urls, in: cleared))
    }

    func testApplyReplacesAnotherSmartListAndKeepsUnrelatedChips() {
        let urls = MacClippySmartListPolicy.catalog[0]
        let images = MacClippySmartListPolicy.catalog[1]
        let withURLs = MacClippySmartListPolicy.apply(urls, to: "notes has:name")
        let withImages = MacClippySmartListPolicy.apply(images, to: withURLs)

        XCTAssertEqual(MacClippySearchGrammar.parse(withImages).bareTerms, ["notes"])
        XCTAssertEqual(
            MacClippySearchGrammar.parse(withImages).clauses,
            [.hasLabel, .type(.image)]
        )
        XCTAssertTrue(MacClippySmartListPolicy.isActive(images, in: withImages))
        XCTAssertFalse(MacClippySmartListPolicy.isActive(urls, in: withImages))
    }

    func testContainsUsesTheListQuery() {
        let urls = MacClippySmartListPolicy.catalog[0]
        let matching = MacClippySearchGrammar.SearchRecord(
            contentKind: .text,
            sourceAppBundleID: "com.example.Editor",
            sourceAppDisplayName: "Editor",
            customLabel: nil,
            ocrText: nil,
            modified: Date(),
            isURL: true
        )
        let other = MacClippySearchGrammar.SearchRecord(
            contentKind: .text,
            sourceAppBundleID: "com.apple.Safari",
            sourceAppDisplayName: "Safari",
            customLabel: nil,
            ocrText: nil,
            modified: Date(),
            isURL: false
        )

        XCTAssertTrue(MacClippySmartListPolicy.contains(matching, in: urls))
        XCTAssertFalse(MacClippySmartListPolicy.contains(other, in: urls))
    }

    func testHidingAListRemovesItFromTheVisibleCatalog() {
        let urls = MacClippySmartListPolicy.catalog[0]
        let images = MacClippySmartListPolicy.catalog[1]
        let hidden = MacClippySmartListPolicy.hiding(urls, in: [])
        XCTAssertEqual(hidden, [urls.id])
        XCTAssertEqual(
            MacClippySmartListPolicy.visibleCatalog(hiddenIDs: hidden).map(\.id),
            [images.id]
        )
    }

    func testHiddenIDsRoundTripThroughUserDefaults() throws {
        let suiteName = "MacClippySmartListHidden-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(MacClippySmartListPolicy.hiddenIDs(from: defaults).isEmpty)
        MacClippySmartListPolicy.persist(hiddenIDs: ["urls"], to: defaults)
        XCTAssertEqual(MacClippySmartListPolicy.hiddenIDs(from: defaults), ["urls"])
    }
}
