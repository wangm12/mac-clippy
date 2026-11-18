import CryptoKit
import Foundation
import XCTest

@testable import MacClippyCore

final class MacClippyCoreHardeningFixesTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyCoreFixes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testSmartTextCodeLanguageHandlesAdversarialInputQuickly() {
        let repeatedHTML = String(repeating: "<div data-test=\"x\" ", count: 300)
        let repeatedSQL = "SELECT " + String(repeating: "column_name, ", count: 250) + "id"
        let start = Date()
        XCTAssertNil(MacClippySmartText.codeLanguage(repeatedHTML))
        XCTAssertNil(MacClippySmartText.codeLanguage(repeatedSQL))
        XCTAssertEqual(MacClippySmartText.codeLanguage("SELECT id FROM items"), .sql)
        XCTAssertEqual(MacClippySmartText.codeLanguage("<div>hello</div>"), .html)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testThumbnailDiskCacheRemovesAllSizesAndPrunesOrphans() throws {
        let cacheURL = tempRoot.appendingPathComponent("thumbnails", isDirectory: true)
        let cache = MacClippyThumbnailDiskCache(
            directoryURL: cacheURL,
            key: SymmetricKey(size: .bits256)
        )
        let liveID = RecordID.generate()
        let orphanID = RecordID.generate()
        let samplePNG = Data("fake-png".utf8)

        try cache.store(samplePNG, id: liveID, maxPixelSize: 240)
        try cache.store(samplePNG, id: liveID, maxPixelSize: 480)
        try cache.store(samplePNG, id: orphanID, maxPixelSize: 240)
        try cache.store(samplePNG, id: orphanID, maxPixelSize: 480)

        cache.remove(id: liveID)
        XCTAssertNil(cache.pngData(id: liveID, maxPixelSize: 240))
        XCTAssertNil(cache.pngData(id: liveID, maxPixelSize: 480))
        XCTAssertEqual(cache.pngData(id: orphanID, maxPixelSize: 240), samplePNG)

        let keptID = RecordID.generate()
        try cache.store(samplePNG, id: keptID, maxPixelSize: 480)
        try cache.pruneOrphans { batch in
            Set(batch.filter { $0 == keptID })
        }
        XCTAssertEqual(cache.pngData(id: keptID, maxPixelSize: 480), samplePNG)
        XCTAssertNil(cache.pngData(id: orphanID, maxPixelSize: 240))
        XCTAssertNil(cache.pngData(id: orphanID, maxPixelSize: 480))
    }

    func testSearchStoreSubstringSearchAndMetadataAppLabelFilters() throws {
        let clipDB = try MacClippyDatabase(url: tempRoot.appendingPathComponent("clipboard.sqlite"))
        let searchDB = try MacClippyDatabase(url: tempRoot.appendingPathComponent("search.sqlite"))
        defer {
            try? clipDB.queue.close()
            try? searchDB.queue.close()
        }
        let store = try ClipboardStore(database: clipDB, deviceKey: SymmetricKey(size: .bits256))
        let search = try SearchStore(database: searchDB)

        let safariItem = try store.append(
            .text("alpha_invoice_report"),
            sourceAppBundleID: "com.apple.Safari",
            sourceAppDisplayName: "Safari"
        )
        _ = try store.setCustomLabel(id: safariItem.id, label: "QuarterlyTax")
        try search.upsert(id: safariItem.id, text: "alpha_invoice_report QuarterlyTax Safari")

        let notesItem = try store.append(
            .text("beta_invoice_draft"),
            sourceAppBundleID: "com.apple.Notes",
            sourceAppDisplayName: "Notes"
        )
        try search.upsert(id: notesItem.id, text: "beta_invoice_draft Notes")

        let filter = MacClippyClipboardMetadataFilter(
            sourceAppContains: ["safari"],
            labelContains: ["tax"]
        )
        let scopedIDs = try store.matchingRecordIDs(filter: filter)
        XCTAssertEqual(scopedIDs, [safariItem.id])

        let hits = try search.search(terms: ["invoice_"], limit: 10, matchingRecordIDs: scopedIDs)
        XCTAssertEqual(hits.map(\.id), [safariItem.id])
    }
}
