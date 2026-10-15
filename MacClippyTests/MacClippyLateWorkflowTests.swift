import AppKit
import MacClippyCore
import MacClippyPlatform
import SwiftUI
import XCTest

@testable import MacClippy

final class MacClippyLateWorkflowTests: XCTestCase {
    private var root: URL!
    private var board: NSPasteboard!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyLateWorkflow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        board = NSPasteboard(name: .init("MacClippyLateWorkflow-\(UUID())"))
        board.setString("unchanged", forType: .string)
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
    func testExplicitPreviewAndDetailsNavigateFromDisplayedIDWithoutChangingFocusOnOpen() throws {
        let records = try ["A", "B", "C"].map { try runtime.appendTestRecord(.text($0)) }
        for details in [false, true] {
            let controller = prepareController()
            controller.model.historyItems = try records.map { try XCTUnwrap(runtime.entry(for: $0)) }
            controller.model.focusSelection(at: 1)
            if details {
                controller.showDetails(targetID: records[0].id)
                MacClippyTestWait.until({ controller.details != nil }, failOnTimeout: true)
            } else {
                controller.showPreview(for: .item(records[0].id))
                MacClippyTestWait.until({ self.previewText(controller) == "A" }, failOnTimeout: true)
            }
            XCTAssertEqual(controller.model.focusedItem?.id, records[1].id)
            controller.moveFocusedPreview(direction: .right)
            MacClippyTestWait.until({ details ? controller.details?.id == records[1].id
                : self.previewText(controller) == "B" }, failOnTimeout: true)
            XCTAssertEqual(controller.model.focusedItem?.id, records[1].id)
            if details { XCTAssertEqual(controller.detailsTargetID, records[1].id) } else {
                XCTAssertEqual(controller.previewTarget, .item(records[1].id))
            }
            controller.cleanup()
        }
    }

    @MainActor
    func testExplicitSnippetPreviewNavigatesFromDisplayedID() throws {
        let snippets = try ["A", "B", "C"].map { try runtime.createSnippet(name: $0, trigger: nil, body: $0) }
        let controller = prepareController()
        defer { controller.cleanup() }
        controller.model.selectSnippetsFilter()
        controller.model.snippets = snippets
        controller.model.filteredSnippets = snippets
        controller.model.focusedIndex = 1
        controller.showPreview(for: .snippet(snippets[0].id))
        MacClippyTestWait.until({ self.previewText(controller) == "A" }, failOnTimeout: true)
        XCTAssertEqual(controller.model.focusedSnippet?.id, snippets[1].id)
        controller.moveFocusedPreview(direction: .right)
        MacClippyTestWait.until({ self.previewText(controller) == "B" }, failOnTimeout: true)
        XCTAssertEqual(controller.model.focusedSnippet?.id, snippets[1].id)
        XCTAssertEqual(controller.previewTarget, .snippet(snippets[1].id))
    }

    @MainActor
    func testPickerArrowsAfterPreviewCloseAdvanceFromCurrentHistoryFocus() throws {
        let records = try ["A", "B", "C"].map { try runtime.appendTestRecord(.text($0)) }
        for initialIndex in [0, 1] {
            let controller = prepareController()
            controller.model.historyItems = try records.map { try XCTUnwrap(runtime.entry(for: $0)) }
            controller.model.focusSelection(at: initialIndex)
            controller.showPreview(for: .item(records[0].id))
            MacClippyTestWait.until({ self.previewText(controller) == "A" }, failOnTimeout: true)
            controller.hidePreview()
            let events = try [rightEvent(controller), rightEvent(controller)]
            for (step, event) in events.enumerated() {
                XCTAssertNil(controller.routeKeyEvent(event))
                XCTAssertEqual(controller.model.focusedItem?.id, records[min(initialIndex + step + 1, 2)].id)
                XCTAssertEqual(controller.interactionMode, .picker)
                XCTAssertFalse(controller.model.isPreviewVisible)
            }
            controller.cleanup()
        }
    }

    @MainActor
    func testPickerArrowsAfterSnippetPreviewCloseAdvanceFromCurrentFocus() throws {
        let snippets = try ["A", "B", "C"].map { try runtime.createSnippet(name: $0, trigger: nil, body: $0) }
        for initialIndex in [0, 1] {
            let controller = prepareController()
            controller.model.selectSnippetsFilter()
            controller.model.snippets = snippets
            controller.model.filteredSnippets = snippets
            controller.model.focusedIndex = initialIndex
            controller.showPreview(for: .snippet(snippets[0].id))
            MacClippyTestWait.until({ self.previewText(controller) == "A" }, failOnTimeout: true)
            controller.hidePreview()
            let events = try [rightEvent(controller), rightEvent(controller)]
            for (step, event) in events.enumerated() {
                XCTAssertNil(controller.routeKeyEvent(event))
                XCTAssertEqual(controller.model.focusedSnippet?.id, snippets[(initialIndex + step + 1) % 3].id)
                XCTAssertEqual(controller.interactionMode, .picker)
                XCTAssertFalse(controller.model.isPreviewVisible)
            }
            controller.cleanup()
        }
    }

    @MainActor
    func testOldPreviewEditCallbackUsesNewDraftWhileRefreshIsPending() throws {
        let original = try runtime.createSnippet(name: "Old", trigger: "old", body: "Old body", folder: "Old")
        let controller = prepareController()
        defer { controller.cleanup() }
        controller.model.snippets = [original]
        controller.showPreview(for: .snippet(original.id))
        MacClippyTestWait.until({ self.previewText(controller) == "Old body" }, failOnTimeout: true)
        let oldEdit = try XCTUnwrap(controller.previewHostingView?.rootView.onEdit)
        let gate = DispatchSemaphore(value: 0)
        controller.model.previewQueue.async { gate.wait() }
        defer { gate.signal() }
        var completed = false
        controller.model.updateSnippet(
            id: original.id, draft: .init(name: "New", trigger: "new", body: "New body", folder: "New"),
            onSuccess: { completed = true }, onFailure: { XCTFail($0) })
        MacClippyTestWait.until({ completed }, failOnTimeout: true)
        XCTAssertEqual(previewText(controller), "Old body")
        oldEdit()
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Edit Snippet" && $0.isVisible })
        let hosting = try XCTUnwrap(window.contentView as? NSHostingView<MacClippyCreateSnippetEditor>)
        XCTAssertEqual(hosting.rootView.form.name, "New")
        XCTAssertEqual(hosting.rootView.form.body, "New body")
        XCTAssertEqual(hosting.rootView.form.trigger, ";new")
        XCTAssertEqual(hosting.rootView.form.folder, "New")
    }

    @MainActor
    func testErrorDetailsReturnRetriesAndLoadingReturnDoesNotPaste() throws {
        let record = try runtime.appendTestRecord(.text("deleted"))
        try runtime.delete(id: record.id)
        let controller = prepareController()
        defer { controller.cleanup() }
        let gate = DispatchSemaphore(value: 0)
        controller.model.workQueue.async { gate.wait() }
        controller.showDetails(targetID: record.id)
        let request = controller.detailsRequestID
        XCTAssertTrue(controller.detailsIsLoading)
        let event = try returnEvent(controller)
        XCTAssertNil(controller.routeKeyEvent(event))
        XCTAssertEqual(controller.detailsRequestID, request)
        gate.signal()
        controller.model.workQueue.sync {}
        MacClippyMainHop.flushCapturedWork()
        XCTAssertFalse(controller.detailsIsLoading)
        let operation = controller.model.operationGeneration
        XCTAssertNil(controller.routeKeyEvent(try returnEvent(controller)))
        XCTAssertEqual(controller.detailsRequestID, request + 1)
        XCTAssertEqual(controller.model.operationGeneration, operation)
        XCTAssertEqual(controller.detailsTargetID, record.id)
        XCTAssertEqual(board.string(forType: .string), "unchanged")
    }

    @MainActor
    func testSnippetPickerDeleteKeysRouteToSnippetStorageAndKeepOtherSnippet() throws {
        for code: UInt16 in [51, 117] {
            let first = try runtime.createSnippet(name: "Delete", trigger: nil, body: "Delete body")
            let other = try runtime.createSnippet(name: "Keep", trigger: nil, body: "Keep body")
            let controller = prepareController()
            controller.model.selectSnippetsFilter()
            controller.model.snippets = [first, other]
            controller.model.filteredSnippets = [first, other]
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: controller.panel?.windowNumber ?? 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
            XCTAssertNil(controller.routeKeyEvent(event))
            MacClippyTestWait.until(
                { (try? self.runtime.snippetStore.fetch(id: first.id)) == nil }, failOnTimeout: true)
            XCTAssertEqual(try runtime.snippetStore.fetch(id: other.id).body, "Keep body")
            XCTAssertEqual(board.string(forType: .string), "unchanged")
            controller.cleanup()
        }
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

    @MainActor
    private func returnEvent(_ controller: MacClippyDockController) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.detailsPanel?.windowNumber ?? 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    @MainActor
    private func rightEvent(_ controller: MacClippyDockController) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.panel?.windowNumber ?? 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
    }
}
