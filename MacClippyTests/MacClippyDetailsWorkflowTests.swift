import AppKit
import MacClippyCore
import MacClippyPlatform
import XCTest

@testable import MacClippy

final class MacClippyDetailsWorkflowTests: XCTestCase {
    private var root: URL!
    private var board: NSPasteboard!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyDetailsWorkflow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        board = NSPasteboard(name: .init("MacClippyDetailsWorkflow-\(UUID())"))
        board.setString("previous clipboard", forType: .string)
        let injector = MacClippyPasteInjector(pasteboard: board, isProcessTrusted: { false })
        runtime = try MacClippyRuntime(
            paths: MacClippyPaths(rootURL: root), pasteInjector: injector,
            enableSnippetExpansion: false)
    }

    override func tearDownWithError() throws {
        runtime.closeForTesting()
        try FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testDirtyTracksActualChangesAndCancelReset() throws {
        let record = try runtime.appendTestRecord(.text("Original"))
        let session = MacClippyDetailsEditSession(details: try runtime.details(id: record.id))
        XCTAssertFalse(session.isDirty(editing: .content))
        session.contentDraft = "Changed"
        XCTAssertTrue(session.isDirty(editing: .content))
        session.resetDrafts()
        XCTAssertFalse(session.isDirty(editing: .content))
        XCTAssertEqual(session.contentDraft, "Original")
    }

    @MainActor
    func testSaveAndPasteKeepsEditedIDAfterItLeavesSearchResults() throws {
        let shownRecord = try runtime.appendTestRecord(.text("needle A"))
        let otherRecord = try runtime.appendTestRecord(.text("needle B"))
        _ = try runtime.setCustomLabel(id: shownRecord.id, label: "A")
        _ = try runtime.setCustomLabel(id: otherRecord.id, label: "B")
        let controller = try prepareDetails(id: shownRecord.id)
        controller.model.beginSession()
        controller.model.query = "needle"
        controller.model.reload()
        MacClippyTestWait.until({ controller.model.visibleItems.count == 2 }, failOnTimeout: true)
        controller.model.focusedIndex =
            controller.model.visibleItems.firstIndex { $0.id == otherRecord.id } ?? 0
        controller.saveDetailsContent("edited A", intent: .saveAndPaste)
        MacClippyTestWait.until({ self.board.string(forType: .string) == "edited A" }, failOnTimeout: true)
        XCTAssertEqual(board.string(forType: .string), "edited A")
        XCTAssertEqual(try runtime.clipboardStore.body(for: otherRecord.id), .text("needle B"))
        XCTAssertEqual(try runtime.clipboardStore.body(for: shownRecord.id), .text("edited A"))
    }

    @MainActor
    func testReadonlyDetailsCopyUsesDisplayedIDRatherThanBackgroundFocus() throws {
        let shownRecord = try runtime.appendTestRecord(.text("Shown A"))
        let otherRecord = try runtime.appendTestRecord(.text("Background B"))
        let controller = try prepareDetails(id: shownRecord.id)
        controller.detailsEditing = .none
        controller.model.historyItems = [try XCTUnwrap(runtime.entry(for: otherRecord))]
        _ = controller.applyKeyAction(.copy)
        MacClippyTestWait.until({ self.board.string(forType: .string) == "Shown A" }, failOnTimeout: true)
        XCTAssertEqual(board.string(forType: .string), "Shown A")
    }

    @MainActor
    func testDetailsRetryKeepsDisplayedIDWhenBackgroundFocusChanges() throws {
        let shown = try runtime.appendTestRecord(.text("Shown A"))
        let other = try runtime.appendTestRecord(.text("Other B"))
        let controller = try prepareDetails(id: shown.id)
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 360))
        controller.panel = panel
        controller.swiftUIReduceMotion = true
        panel.orderFrontRegardless()
        defer { controller.cleanup() }
        controller.model.historyItems = [try XCTUnwrap(runtime.entry(for: other))]
        controller.refreshDetails()
        MacClippyTestWait.until({ controller.details != nil }, failOnTimeout: true)
        XCTAssertEqual(controller.detailsTargetID, shown.id)
        XCTAssertEqual(controller.details?.id, shown.id)
    }

    @MainActor
    func testTooLargeSaveLeavesDraftAndErrorInCurrentEditor() throws {
        let shownRecord = try runtime.appendTestRecord(.text("Original"))
        let controller = try prepareDetails(id: shownRecord.id)
        let draft = String(repeating: "x", count: MacClippyDockPreviewTextPolicy.maxRenderedCharacters + 1)
        controller.detailsEditSession?.contentDraft = draft
        controller.saveDetailsContent(draft)
        XCTAssertEqual(controller.detailsEditSession?.contentDraft, draft)
        XCTAssertNotNil(controller.detailsEditSession?.errorMessage)
        XCTAssertFalse(controller.model.isDetailsSaving)
        XCTAssertEqual(try runtime.clipboardStore.body(for: shownRecord.id), .text("Original"))
    }

    @MainActor
    func testSaveFailureKeepsDirtyDraftAndDoesNotPasteAnotherRecord() throws {
        let shown = try runtime.appendTestRecord(.text("Original"))
        let other = try runtime.appendTestRecord(.text("Other"))
        let controller = try prepareDetails(id: shown.id)
        controller.model.historyItems = [try XCTUnwrap(runtime.entry(for: other))]
        try runtime.delete(id: shown.id)
        controller.saveDetailsContent("Unsaved draft", intent: .saveAndPaste)
        MacClippyTestWait.until({ controller.detailsEditSession?.errorMessage != nil }, failOnTimeout: true)
        XCTAssertEqual(controller.detailsEditSession?.contentDraft, "Unsaved draft")
        XCTAssertTrue(controller.detailsEditSession?.isDirty(editing: .content) == true)
        XCTAssertFalse(controller.model.isDetailsSaving)
        XCTAssertEqual(board.string(forType: .string), "previous clipboard")
    }

    @MainActor
    func testCapturedCardCopyDoesNotUseNewBackgroundFocus() throws {
        let shown = try runtime.appendTestRecord(.text("Shown A"))
        let other = try runtime.appendTestRecord(.text("Other B"))
        let model = MacClippyDockModel(runtime: runtime)
        model.historyItems = [try XCTUnwrap(runtime.entry(for: other))]
        model.copyTarget(.item(shown.id))
        MacClippyTestWait.until({ self.board.string(forType: .string) == "Shown A" }, failOnTimeout: true)
        XCTAssertEqual(model.focusedItem?.id, other.id)
        XCTAssertEqual(board.string(forType: .string), "Shown A")
    }

    @MainActor
    func testManualPasteFeedbackRemainsVisibleAfterDockCloses() throws {
        let record = try runtime.appendTestRecord(.text("Manual paste"))
        let controller = MacClippyDockController(runtime: runtime)
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 360))
        controller.panel = panel
        controller.swiftUIReduceMotion = true
        panel.orderFrontRegardless()
        defer { controller.cleanup() }
        controller.model.selectRecord(id: record.id, completion: { controller.hide() })
        MacClippyTestWait.until({ !panel.isVisible }, failOnTimeout: true)
        XCTAssertEqual(board.string(forType: .string), "Manual paste")
        XCTAssertTrue(controller.toastPanel?.isVisible == true)
        XCTAssertEqual(MacClippyDockActionFeedback.pasted(manual: true).title, "Copied — press ⌘V to paste")
    }

    @MainActor
    private func prepareDetails(id: RecordID) throws -> MacClippyDockController {
        let controller = MacClippyDockController(runtime: runtime)
        controller.model.actionToastHandler = { _ in }
        let details = try runtime.details(id: id)
        controller.details = details
        controller.detailsTargetID = id
        controller.detailsEditSession = MacClippyDetailsEditSession(details: details)
        controller.detailsEditing = .content
        controller.interactionMode = .details
        return controller
    }
}
