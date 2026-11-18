import AppKit
import MacClippyCore
import MacClippyPlatform
import SwiftUI
import XCTest

@testable import MacClippy

final class MacClippyNativeSearchWorkflowTests: XCTestCase {
    private var root: URL!
    var board: NSPasteboard!
    var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyNativeSearch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        board = NSPasteboard(name: .init("MacClippyNativeSearch-\(UUID())"))
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
    func testMountedSearchFieldKeepsSpacesDuringIncrementalTypingWithAndWithoutFilters() async throws {
        for hasFilter in [false, true] {
            let controller = prepareMountedController()
            controller.model.query = hasFilter ? "invoice type:text" : "invoice"
            await waitUntil { self.searchField(in: controller.panel?.contentView) != nil }
            controller.enterSearchMode()
            await waitUntil { self.searchField(in: controller.panel?.contentView)?.isEditing == true }
            let field = try XCTUnwrap(searchField(in: controller.panel?.contentView))
            try? await Task.sleep(nanoseconds: 80_000_000)
            field.stringValue = "invoice "
            field.coordinator?.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: field))
            try? await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(field.stringValue, "invoice ")
            field.stringValue += "number"
            field.coordinator?.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: field))
            try? await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(field.stringValue, "invoice number")
            let parsed = MacClippySearchGrammar.parse(controller.model.query)
            XCTAssertEqual(parsed.bareTerms, ["invoice", "number"])
            XCTAssertEqual(parsed.clauses, hasFilter ? [.type(.text)] : [])
            controller.cleanup()
        }
    }

    @MainActor
    func testMountedModalCancellationRestoresSearchModeBeforeFirstReturn() async throws {
        let record = try runtime.appendTestRecord(.text("invoice payload"))
        let controller = prepareMountedController()
        defer { controller.cleanup() }
        controller.model.historyItems = [try XCTUnwrap(runtime.entry(for: record))]
        controller.model.historyQuery = "invoice type:text"
        controller.model.query = "invoice type:text"
        await waitUntil { self.searchField(in: controller.panel?.contentView) != nil }
        controller.enterSearchMode()
        await waitUntil { self.searchField(in: controller.panel?.contentView)?.isEditing == true }
        controller.model.modal = .createCategory(token: 1)
        await waitUntil { controller.interactionMode == .modal }
        controller.model.dismissModal()
        await waitUntil {
            controller.interactionMode == .search
                && self.searchField(in: controller.panel?.contentView)?.isEditing == true
        }
        XCTAssertEqual(controller.model.query, "invoice type:text")
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.panel?.windowNumber ?? 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertNil(controller.routeKeyEvent(event))
        controller.model.workQueue.sync {}
        MacClippyMainHop.flushCapturedWork()
        XCTAssertEqual(controller.interactionMode, .picker)
        XCTAssertTrue(controller.panel?.isVisible == true)
        XCTAssertNil(controller.model.actionFeedback)
        XCTAssertEqual(board.string(forType: .string), "unchanged")
        XCTAssertEqual(controller.model.focusedItem?.id, record.id)
    }

    @MainActor
    func testNativeMenuBlurThenModalCancellationRetainsSearchIntent() async throws {
        let record = try runtime.appendTestRecord(.text("invoice payload"))
        for menuEndsBeforeModal in [false, true] {
            let controller = prepareMountedController()
            controller.model.historyItems = [try XCTUnwrap(runtime.entry(for: record))]
            controller.model.historyQuery = "invoice type:text"
            controller.model.query = "invoice type:text"
            await waitUntil { self.searchField(in: controller.panel?.contentView) != nil }
            controller.enterSearchMode()
            await waitUntil { self.searchField(in: controller.panel?.contentView)?.isEditing == true }
            let field = try XCTUnwrap(searchField(in: controller.panel?.contentView))
            try? await Task.sleep(nanoseconds: 80_000_000)
            XCTAssertTrue(field.coordinator?.parent?.isFocused == true)
            let menu = NSMenu(title: "More actions")
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            controller.panel?.makeFirstResponder(nil)
            XCTAssertFalse(field.isEditing)
            field.coordinator?.controlTextDidEndEditing(
                Notification(name: NSControl.textDidEndEditingNotification, object: field))
            try? await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(controller.interactionMode, .search)
            XCTAssertTrue(controller.model.searchFocusIsRequested)
            if menuEndsBeforeModal {
                NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            }
            controller.model.presentCreateCategory()
            await waitUntil { controller.interactionMode == .modal }
            if !menuEndsBeforeModal {
                NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
            }
            controller.model.dismissModal()
            await waitUntil {
                controller.interactionMode == .search
                    && self.searchField(in: controller.panel?.contentView)?.isEditing == true
            }
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: controller.panel?.windowNumber ?? 0, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            XCTAssertNil(controller.routeKeyEvent(event))
            controller.model.workQueue.sync {}
            MacClippyMainHop.flushCapturedWork()
            XCTAssertEqual(controller.interactionMode, .picker)
            XCTAssertEqual(controller.model.query, "invoice type:text")
            XCTAssertTrue(controller.panel?.isVisible == true)
            XCTAssertNil(controller.model.actionFeedback)
            XCTAssertEqual(board.string(forType: .string), "unchanged")
            XCTAssertEqual(controller.model.focusedItem?.id, record.id)
            controller.cleanup()
        }
    }

    @MainActor
    func prepareMountedController() -> MacClippyDockController {
        let controller = MacClippyDockController(runtime: runtime)
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 100, y: 100, width: 1024, height: 360))
        let view = MacClippyDockView(
            model: controller.model, onClose: { controller.hide() }, onCreateSnippet: {}, onOpenSettings: {},
            onEnterPickerMode: { controller.focusResults() }, onPreview: {},
            onSearchModeChange: { controller.setSearchMode($0) }, onSearchCompositionChange: { _ in },
            onModalPresentationChange: { controller.setModalMode($0) }, onReduceMotionChange: { _ in },
            onLayoutHeightChange: { _ in })
        panel.contentView = NSHostingView(rootView: view)
        panel.animationBehavior = .none
        controller.panel = panel
        controller.swiftUIReduceMotion = true
        controller.model.actionToastHandler = { _ in }
        panel.makeKeyAndOrderFront(nil)
        return controller
    }

    @MainActor
    func searchField(in view: NSView?) -> MacClippyIMESearchField? {
        if let field = view as? MacClippyIMESearchField { return field }
        return view?.subviews.lazy.compactMap { self.searchField(in: $0) }.first
    }

    @MainActor
    func waitUntil(
        _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        for _ in 0..<80 {
            MacClippyMainHop.flushCapturedWork()
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Native mounted view did not settle", file: file, line: line)
    }
}
