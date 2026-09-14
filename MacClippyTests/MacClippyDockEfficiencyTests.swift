import AppKit
import Combine
import CoreGraphics
import ImageIO
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

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

    @MainActor
    func testPickerTypedQuerySurvivesSpuriousEmptyFieldWrite() {
        let model = MacClippyDockModel(runtime: runtime)

        model.appendSearchText("d")
        XCTAssertEqual(model.query, "d")
        XCTAssertFalse(model.allowsEmptySearchFieldOverwrite)

        model.commitSearchFieldText("")
        XCTAssertEqual(model.query, "d")

        model.markSearchFieldEditable()
        model.commitSearchFieldText("")
        XCTAssertEqual(model.query, "")
    }

    @MainActor
    func testPickerTypedQuerySurvivesEmptyFieldWriteAfterMainQueueTurn() {
        let model = MacClippyDockModel(runtime: runtime)
        var didRun = false

        model.appendSearchText("d")
        model.requestSearchFocus()
        XCTAssertFalse(model.allowsEmptySearchFieldOverwrite)

        MacClippyMainHop.async {
            XCTAssertFalse(model.allowsEmptySearchFieldOverwrite)
            model.commitSearchFieldText("")
            XCTAssertEqual(model.query, "d")
            didRun = true
        }

        MacClippyTestWait.until { didRun }
    }

    @MainActor
    func testProgrammaticFocusCollapsesSelectedQueryToEnd() {
        let field = NSTextField(string: "d")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentView = field
        window.makeKeyAndOrderFront(nil)
        defer {
            window.animationBehavior = .none
            window.orderOut(nil)
        }
        XCTAssertTrue(field.becomeFirstResponder())
        field.selectText(nil)
        XCTAssertEqual(field.currentEditor()?.selectedRange, NSRange(location: 0, length: 1))

        MacClippySearchFieldCaretAnchor.apply(
            caret: MacClippyDockSearchQueryWritePolicy.caretAfterProgrammaticFocus(query: "d"),
            from: field
        )

        XCTAssertEqual(field.currentEditor()?.selectedRange, NSRange(location: 1, length: 0))
    }

    @MainActor
    func testFocusedFieldTypedCharacterSurvivesSpuriousEmptyWrite() {
        let model = MacClippyDockModel(runtime: runtime)

        model.commitSearchFieldText("d")
        XCTAssertEqual(model.query, "d")
        XCTAssertFalse(model.allowsEmptySearchFieldOverwrite)

        model.commitSearchFieldText("")
        XCTAssertEqual(model.query, "d")

        model.markSearchFieldEditable()
        model.commitSearchFieldText("")
        XCTAssertEqual(model.query, "")
    }

    @MainActor
    func testMarkedTextEmptyWriteDoesNotClearCommittedQuery() {
        let model = MacClippyDockModel(runtime: runtime)
        model.commitSearchFieldText("你好")
        model.commitSearchFieldText("", hasMarkedText: true)
        XCTAssertEqual(model.query, "你好")
    }

    @MainActor
    func testEmptyOverwriteStartsLockedAndBeginSessionRelocksIt() {
        let model = MacClippyDockModel(runtime: runtime)
        XCTAssertFalse(model.allowsEmptySearchFieldOverwrite)

        model.markSearchFieldEditable()
        XCTAssertTrue(model.allowsEmptySearchFieldOverwrite)

        model.beginSession()
        XCTAssertEqual(model.query, "")
        XCTAssertFalse(model.allowsEmptySearchFieldOverwrite)
    }

    @MainActor
    func testVisibleItemsReusesTheInFlightFilterSnapshot() throws {
        let model = MacClippyDockModel(runtime: runtime)
        model.beginSession()
        model.historyItems = [
            try historyEntry(preview: "alpha"),
            try historyEntry(preview: "document"),
        ]
        model.historyQuery = ""
        model.isLoading = false
        model.query = "d"

        XCTAssertEqual(model.visibleItems.map(\.preview), ["document"])
        XCTAssertEqual(model.visibleItems.map(\.preview), ["document"])
        XCTAssertEqual(model.visibleItemsFilterCount, 1)
    }

    @MainActor
    func testLocalStructuredFilterDoesNotResolveUncachedSourceApps() throws {
        // Bundle ID must not contain the app: term. Grammar also matches the
        // last bundle-ID segment, so `com.example.Uncached` would pass even
        // when the display name stays unresolved.
        MacClippySourceAppResolver.testDisplayNames = [
            "com.example.foo": "Uncached App"
        ]
        defer { MacClippySourceAppResolver.testDisplayNames = [:] }

        let model = MacClippyDockModel(runtime: runtime)
        model.beginSession()
        model.historyItems = [
            try historyEntry(
                preview: "alpha",
                sourceAppBundleID: "com.example.foo",
                sourceAppDisplayName: nil
            )
        ]
        model.historyQuery = ""
        model.isLoading = false
        model.query = "app:Uncached"

        XCTAssertTrue(model.visibleItems.isEmpty)
    }

    @MainActor
    func testHistoryVisibleItemsFilterWhileReloadQueryMismatches() throws {
        let model = MacClippyDockModel(runtime: runtime)
        model.beginSession()
        model.historyItems = [
            try historyEntry(preview: "alpha"),
            try historyEntry(preview: "document"),
        ]
        model.historyQuery = ""
        model.isLoading = false
        model.query = "d"

        XCTAssertEqual(model.visibleItems.map(\.preview), ["document"])
    }

    @MainActor
    func testNonEmptyFieldCommitKeepsEmptyOverwriteBlocked() {
        let model = MacClippyDockModel(runtime: runtime)

        model.appendSearchText("d")
        model.commitSearchFieldText("da")
        XCTAssertEqual(model.query, "da")
        XCTAssertFalse(model.allowsEmptySearchFieldOverwrite)

        model.commitSearchFieldText("")
        XCTAssertEqual(model.query, "da")
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
        XCTAssertEqual(model.query, "type:url")
        XCTAssertEqual(model.selectedTab, .history)

        model.toggleSmartList(urls)
        XCTAssertFalse(MacClippySmartListPolicy.isActive(urls, in: model.query))
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.isAllFilterSelected)
    }

    @MainActor
    func testToggleSmartListUnselectsAllAndOmitsTheDuplicateChip() {
        let model = MacClippyDockModel(runtime: runtime)
        let urls = MacClippySmartListPolicy.catalog[0]

        model.toggleSmartList(urls)

        XCTAssertFalse(model.isAllFilterSelected)
        XCTAssertEqual(model.selectedTab, .history)
        XCTAssertEqual(model.displayedSearchText, "")
        model.commitSearchFieldText("")
        XCTAssertTrue(MacClippySmartListPolicy.isActive(urls, in: model.query))
        XCTAssertEqual(model.searchFilterChips.map(\.token), ["type:url"])
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.mountedSearchFilterChips(
                applied: model.searchFilterChips,
                suggestions: model.searchFilterSuggestions,
                excludingTokens: MacClippySmartListPolicy.visibleListTokens(
                    hiddenIDs: model.hiddenSmartListIDs
                )
            ).contains { $0.token == "type:url" }
        )
    }

    @MainActor
    func testSelectAllFilterClearsTheActiveSmartList() {
        let model = MacClippyDockModel(runtime: runtime)
        let urls = MacClippySmartListPolicy.catalog[0]
        model.query = "invoice"
        model.toggleSmartList(urls)
        XCTAssertFalse(model.isAllFilterSelected)

        model.selectAllFilter()

        XCTAssertTrue(model.isAllFilterSelected)
        XCTAssertEqual(model.selectedTab, .history)
        XCTAssertEqual(model.query, "")
        XCTAssertFalse(MacClippySmartListPolicy.isActive(urls, in: model.query))
        XCTAssertEqual(model.displayedSearchText, "")
    }

    @MainActor
    func testRailPillsIgnoreStaleSearchResidueAndKeepCardsVisible() throws {
        let model = MacClippyDockModel(runtime: runtime)
        let url = try historyEntry(preview: "https://example.com/macclippy")
        let image = try historyEntry(preview: "Screenshot", contentKind: .image)
        let text = try historyEntry(preview: "just a sentence")
        model.historyItems = [url, image, text]
        model.snippets = [MacClippySnippetEntry(snippet: Snippet(name: "sig", body: "Thanks"))]
        model.query = "typeimage"
        XCTAssertTrue(model.visibleItems.isEmpty)

        model.toggleSmartList(MacClippySmartListPolicy.catalog[0])
        model.commitSearchFieldText("typeimage")
        XCTAssertEqual(model.query, "type:url")
        XCTAssertEqual(model.visibleItems.map(\.id), [url.id])

        model.toggleSmartList(MacClippySmartListPolicy.catalog[1])
        model.commitSearchFieldText("type:image")
        XCTAssertEqual(model.query, "type:image")
        XCTAssertEqual(model.visibleItems.map(\.id), [image.id])

        model.selectSnippetsFilter()
        model.commitSearchFieldText("typeimage")
        XCTAssertEqual(model.selectedTab, .snippets)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.visibleSnippets.map(\.name), ["sig"])

        model.selectAllFilter()
        model.commitSearchFieldText("typeimage")
        XCTAssertTrue(model.isAllFilterSelected)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.visibleItems.map(\.id), [url.id, image.id, text.id])
    }

    @MainActor
    func testSelectSnippetsFilterDoesNotPassThroughHistoryEmptyState() throws {
        let model = MacClippyDockModel(runtime: runtime)
        model.historyItems = [try historyEntry(preview: "just a sentence")]
        model.snippets = [MacClippySnippetEntry(snippet: Snippet(name: "sig", body: "Thanks"))]
        model.toggleSmartList(MacClippySmartListPolicy.catalog[1])
        XCTAssertTrue(model.visibleItems.isEmpty)

        model.selectSnippetsFilter()

        XCTAssertEqual(model.selectedTab, .snippets)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.filterSurfaceID, "snippets")
        XCTAssertEqual(model.visibleSnippets.map(\.name), ["sig"])
        XCTAssertTrue(model.visibleItems.isEmpty)
    }

    @MainActor
    func testSelectAllFilterReloadsAfterSnippetsLeavesAFilteredHistorySnapshot() throws {
        let model = MacClippyDockModel(runtime: runtime)
        model.historyItems = []
        model.historyQuery = "type:image"
        model.snippets = [MacClippySnippetEntry(snippet: Snippet(name: "sig", body: "Thanks"))]
        model.selectSnippetsFilter()
        XCTAssertEqual(model.selectedTab, .snippets)
        XCTAssertTrue(model.visibleItems.isEmpty)

        model.selectAllFilter()

        XCTAssertEqual(model.selectedTab, .history)
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.isLoading)
        XCTAssertTrue(
            MacClippyDockSessionOpenPolicy.shouldReloadHistoryForAllFilter(
                historyQuery: "type:image",
                query: ""
            )
        )
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

    private func historyEntry(
        preview: String,
        sourceAppBundleID: String? = nil,
        sourceAppDisplayName: String? = nil,
        contentKind: ContentKind = .text
    ) throws -> MacClippyHistoryEntry {
        MacClippyHistoryEntry(
            meta: ClipboardItemMeta(
                id: .generate(),
                created: Date(timeIntervalSince1970: 1),
                modified: Date(timeIntervalSince1970: 1),
                deviceID: try XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                lamport: 1,
                preview: preview,
                sourceAppBundleID: sourceAppBundleID,
                sourceAppDisplayName: sourceAppDisplayName
            ),
            contentKind: contentKind,
            preview: preview
        )
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
