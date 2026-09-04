import Combine
import CoreGraphics
import ImageIO
import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippyDockEfficiencyTests: XCTestCase {
    private var tempRoot: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyDockEfficiencyTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: tempRoot))
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    @MainActor
    func testQueryChangeCachesHighlightTermsOnce() {
        let model = MacClippyDockModel(runtime: runtime)

        model.query = "hello world"
        XCTAssertEqual(model.highlightTerms, ["hello", "world"])

        model.query = "hello world"
        XCTAssertEqual(model.highlightTerms, ["hello", "world"])

        model.query = ""
        XCTAssertEqual(model.highlightTerms, [])
    }

    @MainActor
    func testQueryChangeBuildsRemovableFilterChips() {
        let model = MacClippyDockModel(runtime: runtime)

        model.query = "invoice type:image has:ocr"
        XCTAssertEqual(model.highlightTerms, ["invoice"])
        XCTAssertEqual(model.searchFilterChips.map(\.token), ["type:image", "has:ocr"])
        XCTAssertFalse(model.searchFilterSuggestions.contains { $0.token == "has:ocr" })

        model.removeSearchFilter(token: "type:image")
        XCTAssertEqual(MacClippySearchGrammar.parse(model.query).clauses, [.hasOCR])
        XCTAssertEqual(model.highlightTerms, ["invoice"])

        model.appendSearchFilter(token: "type:text")
        XCTAssertTrue(model.query.contains("type:text"))
    }

    func testStorageUsageCountsItemsAndCompressLeavesTinyImages() throws {
        _ = try runtime.appendTestRecord(.text("hello"))
        _ = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))

        let envelopeDecrypts = runtime.clipboardStore.recordEnvelopeDecryptCount
        let usage = try runtime.storageUsage()
        XCTAssertEqual(usage.itemCount, 2)
        XCTAssertGreaterThan(usage.imageBytes, 0)
        XCTAssertGreaterThan(usage.totalBytes, 0)
        XCTAssertEqual(usage.maxItems, MacClippyStorageCapPolicy.defaultMaxItems)
        XCTAssertEqual(
            runtime.clipboardStore.recordEnvelopeDecryptCount,
            envelopeDecrypts,
            "Settings storage scan must not open every image envelope"
        )

        let report = try runtime.compressOldImages()
        XCTAssertEqual(report.compressedCount, 0)
        XCTAssertEqual(report.bytesSaved, 0)
        XCTAssertEqual(
            MacClippyStorageDashboardPolicy.compressMessage(
                compressedCount: report.compressedCount,
                bytesSaved: report.bytesSaved
            ),
            "No old images needed compression."
        )
    }

    @MainActor
    func testToggleSmartListAppliesAndClearsTheSavedQuery() {
        let model = MacClippyDockModel(runtime: runtime)
        let urls = MacClippySmartListPolicy.catalog[0]
        model.query = "invoice"
        model.selectTab(.snippets)

        model.toggleSmartList(urls)

        XCTAssertTrue(MacClippySmartListPolicy.isActive(urls, in: model.query))
        XCTAssertEqual(MacClippySearchGrammar.parse(model.query).bareTerms, ["invoice"])
        XCTAssertEqual(model.selectedTab, .history)

        model.toggleSmartList(urls)
        XCTAssertFalse(MacClippySmartListPolicy.isActive(urls, in: model.query))
        XCTAssertEqual(model.query, "invoice")
    }

    @MainActor
    func testHideSmartListRemovesThePillAndClearsAnActiveQuery() throws {
        let suiteName = "MacClippySmartListHide-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = MacClippyDockModel(runtime: runtime, defaults: defaults)
        let urls = MacClippySmartListPolicy.catalog[0]
        model.toggleSmartList(urls)
        XCTAssertTrue(MacClippySmartListPolicy.isActive(urls, in: model.query))

        model.hideSmartList(urls)

        XCTAssertFalse(model.visibleSmartLists.contains(where: { $0.id == urls.id }))
        XCTAssertFalse(MacClippySmartListPolicy.isActive(urls, in: model.query))
        XCTAssertEqual(MacClippySmartListPolicy.hiddenIDs(from: defaults), [urls.id])
    }

    @MainActor
    func testTypingDoesNotBumpSelectAllGenerationWhenNothingIsSelected() {
        let model = MacClippyDockModel(runtime: runtime)
        let generation = model.selectAllGeneration

        model.query = "hello"

        XCTAssertEqual(model.selectAllGeneration, generation)
        XCTAssertNil(model.allSelectedRecordIDs)
    }

    @MainActor
    func testQueryInvalidatesSelectAllScope() {
        let model = MacClippyDockModel(runtime: runtime)
        model.allSelectedRecordIDs = [RecordID.generate()]
        model.allSelectedRecordIDSet = Set(model.allSelectedRecordIDs ?? [])

        model.query = "hello"

        XCTAssertNil(model.allSelectedRecordIDs)
        XCTAssertNil(model.allSelectedRecordIDSet)
    }

    @MainActor
    func testRecomputeDedupRunsSkipsNoOpPublish() {
        let model = MacClippyDockModel(runtime: runtime)
        var publishes = 0
        let cancellable = model.$dedupRunCounts.sink { _ in
            publishes += 1
        }

        model.recomputeDedupRuns()
        model.recomputeDedupRuns()
        _ = cancellable

        XCTAssertEqual(publishes, 1)
    }

    @MainActor
    func testEndSessionReleasesThumbnailCache() throws {
        let model = MacClippyDockModel(runtime: runtime)
        let id = RecordID.generate()
        let image = try XCTUnwrap(Self.pngImage())
        model.thumbnailLoader.cache.setObject(
            MacClippyCardThumbnailLoader.CacheEntry(image: image),
            forKey: "\(id.rawValue)#480" as NSString,
            cost: 4
        )
        XCTAssertNotNil(model.thumbnailLoader.cachedImage(id: id, maxPixelSize: 480))

        model.endSession()

        XCTAssertNil(model.thumbnailLoader.cachedImage(id: id, maxPixelSize: 480))
    }

    private static func pngImage() -> CGImage? {
        let png = Data(
            base64Encoded: """
            iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=
            """
        )!
        let source = CGImageSourceCreateWithData(png as CFData, nil)
        return source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}
