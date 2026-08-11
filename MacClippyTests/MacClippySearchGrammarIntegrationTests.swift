import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

// P2b integration tests for the structured search grammar at the runtime and
// dock-model level: structured-only queries fill the result limit, type/app/
// tag/has/before/after clauses filter the existing metadata, mixed bare+
// structured queries AND the FTS result with the predicate, unknown clauses
// degrade to bare FTS terms, and the dock pinboard-tab filter is
// grammar-aware. The pure parser/predicate is covered by MacClippySearchGrammarTests
// in the package test target.
final class MacClippySearchGrammarIntegrationTests: XCTestCase {
    private var tempRoot: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippySearchGrammarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let paths = try MacClippyPaths(rootURL: tempRoot)
        // We never call start(), so the observer never polls. We exercise the
        // runtime's history(search) path directly.
        runtime = try MacClippyRuntime(paths: paths)
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Structured-only queries

    func testStructuredOnlyTypeQueryFillsLimitWithAllMatches() throws {
        // 3 image records and 1 text record. type:image must return all 3
        // images (not underfill by filtering after a 16-row FTS query).
        let image1 = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 1_000))
        let image2 = try runtime.appendTestRecord(.image(blobID: "unused", width: 2, height: 2), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 1_001))
        let image3 = try runtime.appendTestRecord(.image(blobID: "unused", width: 3, height: 3), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 1_002))
        _ = try runtime.appendTestRecord(.text("plain text body"), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 1_003))

        let results = try runtime.history(limit: 16, query: "type:image")
        XCTAssertEqual(Set(results.map(\.id)), Set([image1.id, image2.id, image3.id]))
        XCTAssertTrue(results.allSatisfy { $0.contentKind == .image })
    }

    func testStructuredOnlyTypeQueryRespectsLimit() throws {
        // 5 image records with distinct timestamps; limit 2 returns exactly
        // 2 (the two newest by modified DESC, the existing list ordering).
        var records: [ClipboardItemMeta] = []
        for index in 0..<5 {
            let meta = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: Double(1_000 + index)))
            records.append(meta)
        }
        let results = try runtime.history(limit: 2, query: "type:image")
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.contentKind == .image })
        // Newest first: the last two appended have the highest modified.
        XCTAssertEqual(results.map(\.id), [records[4].id, records[3].id])
    }

    func testStructuredOnlyQueryPaginatesMetadataWithoutChangingOrder() throws {
        var records: [ClipboardItemMeta] = []
        records.reserveCapacity(130)
        for index in 0..<130 {
            records.append(
                try runtime.appendTestRecord(
                    .text("page-(index)"),
                    sourceAppBundleID: nil,
                    now: Date(timeIntervalSince1970: Double(10_000 + index))
                )
            )
        }

        let results = try runtime.history(limit: 130, query: "type:text")

        XCTAssertEqual(results.count, 130)
        XCTAssertEqual(results.map(\.id), records.reversed().map(\.id))
    }

    func testStructuredAndBareSearchWithZeroLimitDoesNoWork() throws {
        _ = try runtime.appendTestRecord(.text("should not be returned"))

        XCTAssertTrue(try runtime.history(limit: 0, query: "type:text").isEmpty)
        XCTAssertTrue(try runtime.history(limit: 0, query: "should").isEmpty)
    }

    func testStructuredOnlyAppQueryFiltersCaseInsensitivelyBySubstring() throws {
        let editor = try runtime.appendTestRecord(.text("body one"), sourceAppBundleID: "com.Example.Editor", now: Date(timeIntervalSince1970: 1_000))
        _ = try runtime.appendTestRecord(.text("body two"), sourceAppBundleID: "com.other.App", now: Date(timeIntervalSince1970: 2_000))

        let results = try runtime.history(limit: 16, query: "app:example")
        XCTAssertEqual(results.map(\.id), [editor.id])
        // Case-insensitive substring.
        XCTAssertEqual(try runtime.history(limit: 16, query: "app:EDITOR").map(\.id), [editor.id])
    }

    func testStructuredOnlyTagAndLabelAreAliasesOnCustomLabel() throws {
        let withLabel = try runtime.appendTestRecord(.text("body one"), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 1_000))
        _ = try runtime.setCustomLabel(id: withLabel.id, label: "Project Alpha")
        _ = try runtime.appendTestRecord(.text("body two"), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(try runtime.history(limit: 16, query: "tag:project").map(\.id), [withLabel.id])
        XCTAssertEqual(try runtime.history(limit: 16, query: "label:alpha").map(\.id), [withLabel.id])
        // Quoted multi-word label value.
        XCTAssertEqual(try runtime.history(limit: 16, query: "tag:\"project alpha\"").map(\.id), [withLabel.id])
    }

    func testStructuredOnlyHasLabelAndHasOCR() throws {
        let withLabel = try runtime.appendTestRecord(.text("body one"), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 1_000))
        _ = try runtime.setCustomLabel(id: withLabel.id, label: "kept")

        let imageWithOCR = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 1_500))
        try runtime.setOCRTextForTest(id: imageWithOCR.id, text: "scanned words")

        _ = try runtime.appendTestRecord(.text("no label no ocr"), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 2_000))

        // has:label returns only the labeled record.
        XCTAssertEqual(Set(try runtime.history(limit: 16, query: "has:label").map(\.id)), Set([withLabel.id]))
        // has:ocr returns only the image with OCR text.
        XCTAssertEqual(Set(try runtime.history(limit: 16, query: "has:ocr").map(\.id)), Set([imageWithOCR.id]))
    }

    func testStructuredOnlyBeforeAndAfterDateFilters() throws {
        // Use explicit timestamps so the local-day boundary is deterministic.
        // Day start for 2026-07-10 in the local calendar.
        let dayStart = startOfDay(components: (2026, 7, 10))

        let beforeDay = try runtime.appendTestRecord(.text("earlier"), sourceAppBundleID: nil, now: dayStart.addingTimeInterval(-60))
        let atDayStart = try runtime.appendTestRecord(.text("at start"), sourceAppBundleID: nil, now: dayStart)
        let afterDay = try runtime.appendTestRecord(.text("later"), sourceAppBundleID: nil, now: dayStart.addingTimeInterval(60))

        // before:2026-07-10 -> strictly before dayStart: only beforeDay.
        XCTAssertEqual(try runtime.history(limit: 16, query: "before:2026-07-10").map(\.id), [beforeDay.id])
        // after:2026-07-10 -> on or after dayStart: atDayStart and afterDay.
        XCTAssertEqual(Set(try runtime.history(limit: 16, query: "after:2026-07-10").map(\.id)), Set([atDayStart.id, afterDay.id]))
    }

    func testStructuredOnlyInvalidDateDegradesToBareFTSTerm() throws {
        // An invalid date must not crash and must degrade to a bare term that
        // narrows via FTS (matching the indexed literal) rather than
        // broadening to all records. setCustomLabel indexes body + label so
        // the degraded bare term is searchable.
        let meta = try runtime.appendTestRecord(.text("before:2026-13-40 literal"), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 1_000))
        _ = try runtime.setCustomLabel(id: meta.id, label: "x")

        let results = try runtime.history(limit: 16, query: "before:2026-13-40")
        XCTAssertEqual(results.map(\.id), [meta.id])
    }

    // MARK: - Mixed bare + structured

    func testMixedBareAndStructuredANDsFTSWithPredicate() throws {
        // Two text records whose bodies contain "important"; only one has the
        // label "work". setCustomLabel indexes body + label so FTS can match
        // the body term, and the structured label clause then narrows.
        let work = try runtime.appendTestRecord(.text("important body one"), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 1_000))
        _ = try runtime.setCustomLabel(id: work.id, label: "work")

        let personal = try runtime.appendTestRecord(.text("important body two"), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 2_000))
        _ = try runtime.setCustomLabel(id: personal.id, label: "personal")

        let results = try runtime.history(limit: 16, query: "important label:work")
        XCTAssertEqual(results.map(\.id), [work.id])
        // The FTS snippet is preserved as the preview for bare-term matches.
        XCTAssertEqual(results.first?.id, work.id)
    }

    func testMixedBareAndStructuredDoesNotUnderfillWhenFTSHasEnoughCandidates() throws {
        // 20 text records all contain "commonterm"; half have label "alpha".
        // A bare+structured query commonterm label:alpha with limit 16 must
        // return all 10 alpha records, not underfill by filtering after a
        // 16-row FTS query.
        var alphaIDs: [RecordID] = []
        for index in 0..<20 {
            let meta = try runtime.appendTestRecord(.text("commonterm body \(index)"), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: Double(1_000 + index)))
            _ = try runtime.setCustomLabel(id: meta.id, label: index % 2 == 0 ? "alpha" : "beta")
            if index % 2 == 0 { alphaIDs.append(meta.id) }
        }

        let results = try runtime.history(limit: 16, query: "commonterm label:alpha")
        XCTAssertEqual(Set(results.map(\.id)), Set(alphaIDs))
        XCTAssertEqual(results.count, 10)
    }

    func testMixedBareAndStructuredPaginatesPastOldPoolBoundary() throws {
        // Regression: the old bare+structured path fetched a single fixed FTS
        // pool of max(limit*8, 128) candidates, so a valid structured match
        // living past that pool was missed and the query underfilled. Build
        // enough FTS hits to cross the old 128-candidate boundary and place
        // the only structured match beyond the first page, then verify the
        // mixed query finds it instead of underfilling.
        //
        // 140 filler records and 1 target, all with the identical body
        // "commonterm commonterm commonterm" so FTS5 bm25 scores are equal
        // and `ORDER BY rank` tiebreaks by rowid (insertion order). The
        // target is appended last, so it lands at FTS position 141 — past
        // the old 128-candidate pool. Each record is indexed via
        // setCustomLabel (the same re-index path the existing grammar tests
        // use); fillers get a non-matching label so the label:target
        // predicate discards them, and only the target carries "target".
        for index in 0..<140 {
            let filler = try runtime.appendTestRecord(
                .text("commonterm commonterm commonterm"),
                sourceAppBundleID: nil,
                now: Date(timeIntervalSince1970: Double(index))
            )
            _ = try runtime.setCustomLabel(id: filler.id, label: "filler\(index)")
        }
        let target = try runtime.appendTestRecord(
            .text("commonterm commonterm commonterm"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 1_000_000)
        )
        _ = try runtime.setCustomLabel(id: target.id, label: "target")

        let results = try runtime.history(limit: 16, query: "commonterm label:target")
        XCTAssertEqual(results.map(\.id), [target.id])
        XCTAssertEqual(results.count, 1)
        // The FTS snippet is preserved as the preview for the bare term.
        XCTAssertNotNil(results.first?.preview.range(of: "commonterm"))
    }

    func testUnknownClauseDegradesToBareFTSTerm() throws {
        // foo:bar is an unknown key; it degrades to a bare FTS term so the
        // query narrows (matches the literal "foo:bar") instead of broadening
        // to all records.
        let meta = try runtime.appendTestRecord(.text("foo:bar payload"), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 1_000))
        _ = try runtime.setCustomLabel(id: meta.id, label: "x")

        let results = try runtime.history(limit: 16, query: "foo:bar")
        XCTAssertEqual(results.map(\.id), [meta.id])
    }

    // MARK: - Bare-only behavior preserved

    func testBareOnlyQueryPreservesFTSSnippetAsPreview() throws {
        let meta = try runtime.appendTestRecord(.text("searchable body words"), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 1_000))
        _ = try runtime.setCustomLabel(id: meta.id, label: "irrelevant")

        let results = try runtime.history(limit: 16, query: "searchable")
        XCTAssertEqual(results.map(\.id), [meta.id])
        // The preview is the FTS snippet (contains the matched term), not the
        // full body, preserving the existing bare-only render behavior.
        XCTAssertNotNil(results.first?.preview.range(of: "searchable"))
    }

    func testBareOnlySearchPagesPastOrphanFTSHits() throws {
        var orphanIDs: [RecordID] = []
        for index in 0..<16 {
            let orphan = try runtime.appendTestRecord(
                .text("orphan commonterm \(index)"),
                sourceAppBundleID: nil,
                now: Date(timeIntervalSince1970: Double(index))
            )
            orphanIDs.append(orphan.id)
            _ = try runtime.setCustomLabel(id: orphan.id, label: "orphan")
        }
        let target = try runtime.appendTestRecord(
            .text("healthy commonterm target"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 1_000)
        )
        _ = try runtime.setCustomLabel(id: target.id, label: "target")
        // Delete only the clipboard rows through the store API. The runtime's
        // FTS cleanup is intentionally not involved here, leaving orphan FTS
        // hits for the pagination regression to exercise without crossing the
        // MacClippyCore module's internal database boundary.
        for id in orphanIDs {
            try runtime.clipboardStore.delete(id: id)
        }

        let results = try runtime.history(limit: 1, query: "commonterm")
        XCTAssertEqual(results.map(\.id), [target.id])
    }

    // MARK: - Dock model: pinboard-tab grammar-aware filter

    @MainActor
    func testDockPinboardFilterAppliesStructuredClauses() throws {
        // Build a pinboard with two items: a text record and an image record.
        let textMeta = try runtime.appendTestRecord(.text("alpha body"), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 1_000))
        let imageMeta = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 2_000))
        let board = try runtime.createPinboard(name: "Work", color: nil)
        try runtime.pin(recordID: textMeta.id, to: board.id)
        try runtime.pin(recordID: imageMeta.id, to: board.id)

        let model = MacClippyDockModel(runtime: runtime)
        model.reload()
        // Wait for the pinboard and its items to be loaded.
        wait {
            model.pinboards.contains(where: { $0.id == board.id })
                && model.pinboards.first(where: { $0.id == board.id })?.items.count == 2
        }
        model.selectTab(.pinboard(board.id))

        // Apply a structured query; the Dock now performs a bounded Runtime
        // query so matches outside the initially loaded page are included.
        model.query = "type:image"
        wait { model.visibleItems.map(\.id) == [imageMeta.id] }
        XCTAssertEqual(model.visibleItems.map(\.id), [imageMeta.id])

        // A bare-only query on the same pinboard preserves substring behavior.
        model.query = "alpha"
        wait { model.visibleItems.map(\.id) == [textMeta.id] }
        XCTAssertEqual(model.visibleItems.map(\.id), [textMeta.id])
    }

    @MainActor
    func testDockPinboardFilterBareOnlyPreservesSubstringBehavior() throws {
        let textMeta = try runtime.appendTestRecord(.text("alpha body"), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 1_000))
        let otherMeta = try runtime.appendTestRecord(.text("beta body"), sourceAppBundleID: nil, now: Date(timeIntervalSince1970: 2_000))
        let board = try runtime.createPinboard(name: "Work", color: nil)
        try runtime.pin(recordID: textMeta.id, to: board.id)
        try runtime.pin(recordID: otherMeta.id, to: board.id)

        let model = MacClippyDockModel(runtime: runtime)
        model.reload()
        wait {
            model.pinboards.contains(where: { $0.id == board.id })
                && model.pinboards.first(where: { $0.id == board.id })?.items.count == 2
        }
        model.selectTab(.pinboard(board.id))
        model.query = "alpha"

        // Bare-only pinboard filter preserves the existing substring behavior.
        wait { model.visibleItems.map(\.id) == [textMeta.id] }
        XCTAssertEqual(model.visibleItems.map(\.id), [textMeta.id])
    }

    @MainActor
    func testDockPinboardSearchFindsMatchBeyondInitialPage() throws {
        let board = try runtime.createPinboard(name: "Large", color: nil)
        var records: [ClipboardItemMeta] = []
        for index in 0..<70 {
            let record = try runtime.appendTestRecord(.text(index == 69 ? "needle beyond first page" : "ordinary item"))
            records.append(record)
            try runtime.pin(recordID: record.id, to: board.id)
        }

        let model = MacClippyDockModel(runtime: runtime)
        model.reload()
        wait {
            model.pinboards.first(where: { $0.id == board.id })?.items.count == 64
        }
        model.selectTab(.pinboard(board.id))
        model.query = "needle beyond first page"

        wait { model.visibleItems.map(\.id) == [records[69].id] }
        XCTAssertEqual(model.visibleItems.map(\.id), [records[69].id])
    }

    // MARK: - Helpers

    private func startOfDay(components: (year: Int, month: Int, day: Int)) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        return calendar.date(from: DateComponents(year: components.year, month: components.month, day: components.day, hour: 0, minute: 0, second: 0))!
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
