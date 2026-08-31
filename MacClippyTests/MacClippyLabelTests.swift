import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

// P2a focused tests for the rename feature at the runtime and dock-model
// level: search/index preservation (body + OCR + label), clear retains
// body/OCR searchability while removing the label term, the model action path
// reports nameSaved feedback and reloads, and the type-aware card content
// (customLabel, displayTitle, typeMetadataSubtitle, fileURLs, imageDimensions)
// is presented correctly.
final class MacClippyLabelTests: XCTestCase {
    private var tempRoot: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyLabelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let paths = try MacClippyPaths(rootURL: tempRoot)
        // We never call start(), so the observer never polls. We exercise the
        // runtime's setCustomLabel + history(search) path directly.
        runtime = try MacClippyRuntime(paths: paths)
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Runtime: label persistence + search index preservation

    func testHistoryEntryPreviewIsStableAcrossRepeatedReads() throws {
        let meta = try runtime.appendTestRecord(.text("cached preview"))

        let first = try runtime.history(limit: 10, query: "").first(where: { $0.id == meta.id })
        let second = try runtime.history(limit: 10, query: "").first(where: { $0.id == meta.id })

        XCTAssertEqual(first?.preview, "cached preview")
        XCTAssertEqual(second?.preview, first?.preview)
    }

    func testHistoryEntryCacheReflectsCustomLabelAfterEdit() throws {
        let meta = try runtime.appendTestRecord(.text("cache label body"))
        let before = try runtime.history(limit: 10, query: "").first(where: { $0.id == meta.id })
        XCTAssertNil(before?.customLabel)

        _ = try runtime.setCustomLabel(id: meta.id, label: "updated label")

        let after = try runtime.history(limit: 10, query: "").first(where: { $0.id == meta.id })
        XCTAssertEqual(after?.customLabel, "updated label")
        XCTAssertEqual(after?.preview, "cache label body")
    }

    func testSetCustomLabelMakesLabelAndBodySearchable() throws {
        let meta = try runtime.appendTestRecord(.text("important body text"))
        // appendTestRecord does not index the search store; setCustomLabel
        // rebuilds the index as body + label so both become searchable.
        _ = try runtime.setCustomLabel(id: meta.id, label: "unicorn")

        let byLabel = try runtime.history(limit: 10, query: "unicorn")
        XCTAssertEqual(byLabel.map(\.id), [meta.id])
        let byBody = try runtime.history(limit: 10, query: "important")
        XCTAssertEqual(byBody.map(\.id), [meta.id])
    }

    func testClearingLabelRemovesLabelTermButRetainsBodySearchability() throws {
        let meta = try runtime.appendTestRecord(.text("searchable body words"))
        _ = try runtime.setCustomLabel(id: meta.id, label: "temporary label")

        // Both label and body are searchable after the label is set.
        XCTAssertEqual(try runtime.history(limit: 10, query: "temporary").map(\.id), [meta.id])
        XCTAssertEqual(try runtime.history(limit: 10, query: "searchable").map(\.id), [meta.id])

        // Clear the label: the label term must no longer hit, but the body
        // text must remain searchable (the index was rebuilt as body only).
        _ = try runtime.setCustomLabel(id: meta.id, label: "   ")

        XCTAssertTrue(try runtime.history(limit: 10, query: "temporary").isEmpty)
        XCTAssertEqual(try runtime.history(limit: 10, query: "searchable").map(\.id), [meta.id])
    }

    func testLabelSearchPreservesOCRTextSearchabilityForImages() throws {
        // An image record carries no body searchable text; its searchability
        // comes from OCR text. setCustomLabel rebuilds the index from body +
        // OCR + label, so OCR text must remain searchable after a label edit,
        // and clearing the label must keep OCR searchable.
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 2, height: 3))

        // Simulate OCR completion by writing OCR text directly to the store.
        // The runtime's setCustomLabel reads meta.ocrText for the rebuild.
        try runtime.setOCRTextForTest(id: image.id, text: "scanned sign text")

        _ = try runtime.setCustomLabel(id: image.id, label: "photo label")

        XCTAssertEqual(try runtime.history(limit: 10, query: "scanned").map(\.id), [image.id])
        XCTAssertEqual(try runtime.history(limit: 10, query: "photo").map(\.id), [image.id])

        // Clear the label: OCR text remains searchable, label term is gone.
        _ = try runtime.setCustomLabel(id: image.id, label: "")
        XCTAssertEqual(try runtime.history(limit: 10, query: "scanned").map(\.id), [image.id])
        XCTAssertTrue(try runtime.history(limit: 10, query: "photo").isEmpty)
    }

    func testSetCustomLabelThrowsRecordNotFoundForMissingID() throws {
        let stale = RecordID.generate()
        XCTAssertThrowsError(try runtime.setCustomLabel(id: stale, label: "x")) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .recordNotFound)
        }
    }

    func testDetailsSnapshotAndTextEditKeepSelectionIdentityAndSearchIndex() throws {
        let meta = try runtime.appendTestRecord(.text("before details"))
        let snapshot = try runtime.details(id: meta.id)
        XCTAssertEqual(snapshot.id, meta.id)
        XCTAssertEqual(snapshot.contentKind, .text)
        XCTAssertEqual(snapshot.textContent, "before details")
        XCTAssertTrue(snapshot.isEditable)

        _ = try runtime.edit(id: meta.id, text: "after details")

        let updated = try runtime.details(id: meta.id)
        XCTAssertEqual(updated.id, meta.id)
        XCTAssertEqual(updated.textContent, "after details")
        XCTAssertTrue(try runtime.history(limit: 10, query: "after").contains(where: { $0.id == meta.id }))
        XCTAssertTrue(try runtime.history(limit: 10, query: "before").isEmpty)
    }

    func testDetailsSnapshotIncludesImageMetadataAndOCR() throws {
        let meta = try runtime.appendTestRecord(.image(blobID: "unused", width: 640, height: 480))
        try runtime.setOCRTextForTest(id: meta.id, text: "recognized words")

        let snapshot = try runtime.details(id: meta.id)
        XCTAssertEqual(snapshot.contentKind, .image)
        XCTAssertEqual(snapshot.imageDimensions, CGSize(width: 640, height: 480))
        XCTAssertEqual(snapshot.ocrText, "recognized words")
        XCTAssertFalse(snapshot.isEditable)
    }

    // MARK: - Dock model: nameSaved feedback + reload action path

    @MainActor
    func testModelRenameReportsSavedFeedbackAndReloads() throws {
        let model = MacClippyDockModel(runtime: runtime)
        let meta = try runtime.appendTestRecord(.text("body"))
        model.reload()
        wait { model.historyItems.contains(where: { $0.id == meta.id }) }

        guard let entry = model.historyItems.first(where: { $0.id == meta.id }) else {
            XCTFail("record should be visible after reload")
            return
        }

        model.focus(entry)
        model.renameFocused("  my label  ")

        // The action runs on the work queue; wait for nameSaved feedback.
        wait { model.actionFeedback != nil }
        guard case let .nameSaved(cleared) = model.actionFeedback else {
            XCTFail("expected .nameSaved feedback, got \(String(describing: model.actionFeedback))")
            return
        }
        XCTAssertFalse(cleared, "a non-blank label should report cleared == false")

        // The reload after the action reflects the persisted label.
        wait { model.historyItems.first(where: { $0.id == meta.id })?.customLabel == "my label" }
        XCTAssertEqual(model.historyItems.first(where: { $0.id == meta.id })?.customLabel, "my label")
    }

    @MainActor
    func testModelRenameBlankReportsClearedFeedbackAndClearsName() throws {
        let model = MacClippyDockModel(runtime: runtime)
        let meta = try runtime.appendTestRecord(.text("body"))
        _ = try runtime.setCustomLabel(id: meta.id, label: "existing")
        model.reload()
        wait { model.historyItems.contains(where: { $0.id == meta.id }) }

        guard let entry = model.historyItems.first(where: { $0.id == meta.id }) else {
            XCTFail("record should be visible after reload")
            return
        }
        XCTAssertEqual(entry.customLabel, "existing")

        model.focus(entry)
        // Pass a whitespace-only name: the model trims and reports cleared.
        model.renameFocused("   ")

        wait { model.actionFeedback != nil }
        guard case let .nameSaved(cleared) = model.actionFeedback else {
            XCTFail("expected .nameSaved feedback, got \(String(describing: model.actionFeedback))")
            return
        }
        XCTAssertTrue(cleared, "a blank label should report cleared == true")

        wait { model.historyItems.first(where: { $0.id == meta.id })?.customLabel == nil }
        XCTAssertNil(model.historyItems.first(where: { $0.id == meta.id })?.customLabel)
    }

    @MainActor
    func testModelRenameForArbitraryIDDoesNotRequireFocus() throws {
        // renameItem(id:name:) is the entry point used by the inline editor
        // when the edited card is not the focused one. It must persist without
        // relying on focusedItem.
        let model = MacClippyDockModel(runtime: runtime)
        let meta = try runtime.appendTestRecord(.text("body"))
        model.reload()
        wait { model.historyItems.contains(where: { $0.id == meta.id }) }

        model.renameItem(id: meta.id, name: "editor label")

        wait { model.actionFeedback != nil }
        guard case .nameSaved = model.actionFeedback else {
            XCTFail("expected .nameSaved feedback, got \(String(describing: model.actionFeedback))")
            return
        }
        wait { model.historyItems.first(where: { $0.id == meta.id })?.customLabel == "editor label" }
        XCTAssertEqual(model.historyItems.first(where: { $0.id == meta.id })?.customLabel, "editor label")
    }

    // MARK: - Card metadata / type presentation

    func testHistoryEntryCarriesFileURLsAndImageDimensions() throws {
        let filesMeta = try runtime.appendTestRecord(.files([URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.txt")]))
        let imageMeta = try runtime.appendTestRecord(.image(blobID: "unused", width: 640, height: 480))

        let filesEntry = try runtime.history(limit: 10, query: "").first(where: { $0.id == filesMeta.id })
        let imageEntry = try runtime.history(limit: 10, query: "").first(where: { $0.id == imageMeta.id })

        XCTAssertEqual(filesEntry?.contentKind, .files)
        XCTAssertEqual(filesEntry?.fileURLs.map(\.lastPathComponent), ["a.txt", "b.txt"])
        XCTAssertNil(filesEntry?.imageDimensions)
        XCTAssertEqual(filesEntry?.typeMetadataSubtitle, "2 files")

        XCTAssertEqual(imageEntry?.contentKind, .image)
        XCTAssertEqual(imageEntry?.fileURLs, [])
        XCTAssertEqual(imageEntry?.imageDimensions, CGSize(width: 640, height: 480))
        XCTAssertEqual(imageEntry?.typeMetadataSubtitle, "640×480")
    }

    func testHistoryEntrySingleFileSubtitleUsesFileCountTitle() throws {
        let meta = try runtime.appendTestRecord(.files([URL(fileURLWithPath: "/tmp/report.pdf")]))
        let entry = try runtime.history(limit: 10, query: "").first(where: { $0.id == meta.id })
        XCTAssertEqual(entry?.typeMetadataSubtitle, "1 file")
        XCTAssertEqual(entry?.preview, "report.pdf")
    }

    func testHistoryEntryCustomLabelAndDisplayTitle() throws {
        let meta = try runtime.appendTestRecord(.text("the preview text"))
        _ = try runtime.setCustomLabel(id: meta.id, label: "  My Title  ")
        let entry = try runtime.history(limit: 10, query: "").first(where: { $0.id == meta.id })

        XCTAssertEqual(entry?.customLabel, "My Title")
        XCTAssertEqual(entry?.displayTitle, "My Title")

        // After clearing, displayTitle falls back to the preview so the card
        // never loses its user-facing title text.
        _ = try runtime.setCustomLabel(id: meta.id, label: "")
        let clearedEntry = try runtime.history(limit: 10, query: "").first(where: { $0.id == meta.id })
        XCTAssertNil(clearedEntry?.customLabel)
        XCTAssertEqual(clearedEntry?.displayTitle, clearedEntry?.preview)
    }

    func testInsertRemoteClipboardSampleIsMarkedRemote() throws {
        let meta = try runtime.insertRemoteClipboardSample()
        let entry = try runtime.history(limit: 10, query: "").first(where: { $0.id == meta.id })
        XCTAssertEqual(entry?.isRemoteClipboard, true)
        XCTAssertEqual(entry?.customLabel, "Remote test")
        XCTAssertEqual(entry?.preview, MacClippyClipboardCardPreviewFactory.sampleText)
    }

    func testHistoryEntryMarksRemoteClipboardFromStoredUTI() throws {
        let remote = try runtime.appendTestRecord(
            .text("from phone"),
            representations: [
                MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("from phone".utf8)),
                MacClippyClipboardRepresentation(
                    uti: CaptureExclusionRules.remoteClipboardPasteboardType,
                    payloadBytes: Data()
                )
            ]
        )
        let local = try runtime.appendTestRecord(.text("local only"))

        let entries = try runtime.history(limit: 10, query: "")
        XCTAssertEqual(entries.first(where: { $0.id == remote.id })?.isRemoteClipboard, true)
        XCTAssertEqual(entries.first(where: { $0.id == local.id })?.isRemoteClipboard, false)

        let cached = try runtime.history(limit: 10, query: "")
        XCTAssertEqual(cached.first(where: { $0.id == remote.id })?.isRemoteClipboard, true)
    }

    func testHistoryEntryTypeMetadataSubtitleIsNilForTextKinds() throws {
        let textMeta = try runtime.appendTestRecord(.text("body"))
        let htmlMeta = try runtime.appendTestRecord(.html("<p>hi</p>"))
        let textEntry = try runtime.history(limit: 10, query: "").first(where: { $0.id == textMeta.id })
        let htmlEntry = try runtime.history(limit: 10, query: "").first(where: { $0.id == htmlMeta.id })
        XCTAssertNil(textEntry?.typeMetadataSubtitle)
        XCTAssertNil(htmlEntry?.typeMetadataSubtitle)
    }

    // MARK: - Helpers

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
