import AppKit
import MacClippyCore
import MacClippyPlatform
import SwiftUI
import XCTest

@testable import MacClippy

final class MacClippySurfaceRegressionTests: XCTestCase {
    private var root: URL!
    private var board: NSPasteboard!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippySurfaces-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        board = NSPasteboard(name: .init("MacClippySurfaces-\(UUID())"))
        runtime = try MacClippyRuntime(
            paths: MacClippyPaths(rootURL: root),
            pasteInjector: MacClippyPasteInjector(pasteboard: board, isProcessTrusted: { false }),
            enableSnippetExpansion: false)
        MacClippyMainHop.setCaptureForTesting(true)
    }

    override func tearDownWithError() throws {
        runtime.closeForTesting()
        try FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testSearchShortcutClosesReadonlyDetailsAndKeepsQueryAndSelection() throws {
        let record = try runtime.appendTestRecord(.text("invoice"))
        let controller = prepareController()
        defer { controller.cleanup() }
        controller.model.historyItems = [try XCTUnwrap(runtime.entry(for: record))]
        controller.model.query = "invoice type:text"
        controller.model.focusSelection(at: 0)
        controller.showDetails(targetID: record.id)
        MacClippyTestWait.until({ controller.details != nil }, failOnTimeout: true)
        _ = controller.applyKeyAction(.enterSearch)
        XCTAssertEqual(controller.interactionMode, .search)
        XCTAssertFalse(controller.detailsPanel?.isVisible == true)
        XCTAssertNil(controller.detailsTargetID)
        XCTAssertNil(controller.detailsEditSession)
        XCTAssertEqual(controller.model.query, "invoice type:text")
        XCTAssertEqual(controller.model.focusedItem?.id, record.id)
    }

    @MainActor
    func testSearchDuringDetailsLoadInvalidatesLateCompletion() throws {
        let record = try runtime.appendTestRecord(.text("invoice"))
        let controller = prepareController()
        defer { controller.cleanup() }
        let gate = DispatchSemaphore(value: 0)
        controller.model.workQueue.async { gate.wait() }
        controller.showDetails(targetID: record.id)
        _ = controller.applyKeyAction(.enterSearch)
        gate.signal()
        controller.model.workQueue.sync {}
        MacClippyMainHop.flushCapturedWork()
        XCTAssertEqual(controller.interactionMode, .search)
        XCTAssertNil(controller.details)
        XCTAssertNil(controller.detailsTargetID)
        XCTAssertFalse(controller.detailsPanel?.isVisible == true)
    }

    @MainActor
    func testSavingDetailsPreventsSearchAndNavigationTransitions() throws {
        let record = try runtime.appendTestRecord(.text("invoice"))
        let other = try runtime.appendTestRecord(.text("other"))
        let controller = prepareController()
        defer { controller.cleanup() }
        controller.model.historyItems = try [record, other].map { try XCTUnwrap(runtime.entry(for: $0)) }
        controller.showDetails(targetID: record.id)
        MacClippyTestWait.until({ controller.details != nil }, failOnTimeout: true)
        controller.detailsEditSession?.isSaving = true
        _ = controller.applyKeyAction(.enterSearch)
        controller.moveFocusedPreview(direction: .right)
        XCTAssertEqual(controller.interactionMode, .details)
        XCTAssertEqual(controller.detailsTargetID, record.id)
        XCTAssertEqual(controller.model.focusedIndex, 0)
        controller.detailsEditSession?.isSaving = false
    }

    @MainActor
    func testDetailsArrowsLoadNewFocusedRecordWhileRetryKeepsDisplayedRecord() throws {
        let first = try runtime.appendTestRecord(.text("first"))
        let second = try runtime.appendTestRecord(.text("second"))
        let controller = prepareController()
        defer { controller.cleanup() }
        controller.model.historyItems = try [first, second].map { try XCTUnwrap(runtime.entry(for: $0)) }
        controller.model.focusSelection(at: 0)
        controller.showDetails(targetID: first.id)
        MacClippyTestWait.until({ controller.details?.id == first.id }, failOnTimeout: true)
        _ = controller.applyKeyAction(.moveFocus(.right))
        MacClippyTestWait.until({ controller.details?.id == second.id }, failOnTimeout: true)
        XCTAssertEqual(controller.model.focusedItem?.id, second.id)
        XCTAssertEqual(controller.detailsTargetID, second.id)
        controller.model.focusedIndex = 0
        controller.refreshDetails()
        MacClippyTestWait.until({ controller.details != nil }, failOnTimeout: true)
        XCTAssertEqual(controller.details?.id, second.id)
    }

    @MainActor
    func testSnippetDetailsShortcutOpensEditorForDisplayedSnippet() throws {
        let shown = try runtime.createSnippet(name: "Shown", trigger: "shown", body: "Shown body")
        let other = try runtime.createSnippet(name: "Other", trigger: "other", body: "Other body")
        let controller = prepareController()
        defer { controller.cleanup() }
        controller.model.snippets = [shown, other]
        controller.previewTarget = .snippet(shown.id)
        controller.interactionMode = .preview
        _ = controller.applyKeyAction(.showDetails)
        XCTAssertTrue(controller.snippetEditorWindow.isPresented)
        XCTAssertNil(controller.detailsTargetID)
        XCTAssertFalse(controller.detailsPanel?.isVisible == true)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Edit Snippet" && $0.isVisible })
        let hosting = try XCTUnwrap(window.contentView as? NSHostingView<MacClippyCreateSnippetEditor>)
        XCTAssertEqual(hosting.rootView.form.name, "Shown")
        XCTAssertEqual(hosting.rootView.form.body, "Shown body")
    }

    @MainActor
    func testSnippetSaveRefreshesSamePreviewAfterItLeavesResults() throws {
        let snippet = try runtime.createSnippet(name: "Needle", trigger: "old", body: "Needle body")
        let controller = prepareController()
        defer { controller.cleanup() }
        controller.model.selectSnippetsFilter()
        controller.model.snippets = [snippet]
        controller.model.query = "Needle"
        controller.showPreview(for: .snippet(snippet.id))
        MacClippyTestWait.until({ self.previewText(controller) == "Needle body" }, failOnTimeout: true)
        var completed = false
        controller.model.updateSnippet(
            id: snippet.id, draft: .init(name: "Renamed", trigger: "new", body: "Changed body", folder: "Work"),
            onSuccess: { completed = true }, onFailure: { XCTFail($0) })
        MacClippyTestWait.until({ completed && self.previewText(controller) == "Changed body" }, failOnTimeout: true)
        XCTAssertEqual(controller.previewTarget, .snippet(snippet.id))
        XCTAssertEqual(controller.model.query, "Needle")
        _ = controller.applyKeyAction(.copy)
        MacClippyTestWait.until({ self.board.string(forType: .string) == "Changed body" }, failOnTimeout: true)
        XCTAssertEqual(runtime.snippetLookupSnapshot.body(for: ";new"), "Changed body")
    }

    @MainActor
    func testLateSnippetSaveDoesNotReplaceAnotherPreview() throws {
        let edited = try runtime.createSnippet(name: "Edited", trigger: nil, body: "A")
        let shown = try runtime.createSnippet(name: "Shown", trigger: nil, body: "B")
        let controller = prepareController()
        defer { controller.cleanup() }
        controller.model.snippets = [edited, shown]
        controller.showPreview(for: .snippet(shown.id))
        MacClippyTestWait.until({ self.previewText(controller) == "B" }, failOnTimeout: true)
        let request = controller.previewRequestID
        var completed = false
        controller.model.updateSnippet(
            id: edited.id, draft: .init(name: "Changed", trigger: nil, body: "Changed A", folder: nil),
            onSuccess: { completed = true }, onFailure: { XCTFail($0) })
        MacClippyTestWait.until({ completed }, failOnTimeout: true)
        XCTAssertEqual(controller.previewTarget, .snippet(shown.id))
        XCTAssertEqual(controller.previewRequestID, request)
        XCTAssertEqual(previewText(controller), "B")
    }

    @MainActor
    func testSnippetSaveFromOldSessionDoesNotRefreshReopenedPreview() throws {
        let snippet = try runtime.createSnippet(name: "Original", trigger: nil, body: "Original body")
        let controller = prepareController()
        defer { controller.cleanup() }
        let gate = DispatchSemaphore(value: 0)
        controller.model.workQueue.async { gate.wait() }
        var completed = false
        controller.model.updateSnippet(
            id: snippet.id, draft: .init(name: "Changed", trigger: nil, body: "Changed body", folder: nil),
            onSuccess: { completed = true }, onFailure: { XCTFail($0) })
        controller.model.endSession()
        controller.model.beginSession()
        controller.previewTarget = .snippet(snippet.id)
        controller.interactionMode = .preview
        let request = controller.previewRequestID
        gate.signal()
        controller.model.workQueue.sync {}
        MacClippyMainHop.flushCapturedWork()
        XCTAssertTrue(completed)
        XCTAssertEqual(controller.previewRequestID, request)
        XCTAssertNil(controller.model.actionFeedback)
        XCTAssertEqual(try runtime.snippetStore.fetch(id: snippet.id).body, "Changed body")
    }

    @MainActor
    func testPinShortcutUsesSingleSelectionOrInitialFocusAndDisplayedPreview() throws {
        let first = try runtime.appendTestRecord(.text("first"))
        let second = try runtime.appendTestRecord(.text("second"))
        _ = try runtime.createPinboard(name: "Target", color: nil)
        let controller = prepareController()
        defer { controller.cleanup() }
        controller.model.historyItems = try [first, second].map { try XCTUnwrap(runtime.entry(for: $0)) }
        controller.model.pinboards = try runtime.pinboards()
        for explicitSelection in [false, true] {
            if explicitSelection { controller.model.focusSelection(at: 0) }
            _ = controller.applyKeyAction(.pinSelection)
            guard case .choosePinboard(let ids, _) = controller.model.modal else { return XCTFail("Missing chooser") }
            XCTAssertEqual(ids, [first.id])
            controller.model.dismissModal()
        }
        controller.previewTarget = .item(second.id)
        controller.interactionMode = .preview
        _ = controller.applyKeyAction(.pinSelection)
        guard case .choosePinboard(let ids, _) = controller.model.modal else {
            return XCTFail("Missing preview chooser")
        }
        XCTAssertEqual(ids, [second.id])
    }

    @MainActor
    func testOldToastDismissalCannotHideNewToastAndNewToastExpires() async {
        let controller = prepareController()
        defer { controller.cleanup() }
        controller.showCopyToast(title: "Old", duration: 10)
        controller.dismissCopyToast()
        controller.showCopyToast(title: "Copied — press ⌘V to paste", duration: 0.4)
        try? await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertTrue(controller.toastPanel?.isVisible == true)
        try? await Task.sleep(nanoseconds: 420_000_000)
        XCTAssertFalse(controller.toastPanel?.isVisible == true)
    }

    @MainActor
    private func prepareController() -> MacClippyDockController {
        let controller = MacClippyDockController(runtime: runtime)
        controller.panel = MacClippyDockPanel(contentRect: NSRect(x: 100, y: 100, width: 800, height: 360))
        controller.panel?.animationBehavior = .none
        controller.swiftUIReduceMotion = true
        controller.panel?.orderFrontRegardless()
        controller.model.actionToastHandler = { _ in }
        return controller
    }

    @MainActor
    private func previewText(_ controller: MacClippyDockController) -> String? {
        guard case let .text(_, value, _)? = controller.previewHostingView?.rootView.content else { return nil }
        return value
    }
}
