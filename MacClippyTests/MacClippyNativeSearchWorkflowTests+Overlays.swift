import AppKit
import MacClippyCore
import MacClippyPlatform
import XCTest

@testable import MacClippy

extension MacClippyNativeSearchWorkflowTests {
    @MainActor
    func testDelayedOverlayCloseCannotOverwriteNewSessionSearchOrExplicitPreview() async throws {
        let record = try runtime.appendTestRecord(.text("overlay payload"))
        for newSession in [false, true] {
            let controller = prepareMountedController()
            await waitUntil { self.searchField(in: controller.panel?.contentView) != nil }
            controller.enterSearchMode()
            await waitUntil { self.searchField(in: controller.panel?.contentView)?.isEditing == true }
            controller.model.presentCreateCategory()
            await waitUntil { controller.interactionMode == .modal }
            controller.model.dismissModal()
            if newSession {
                controller.model.beginSession()
                controller.enterSearchMode()
            } else {
                controller.showPreview(for: .item(record.id))
            }
            try? await Task.sleep(nanoseconds: 160_000_000)
            MacClippyMainHop.flushCapturedWork()
            XCTAssertEqual(controller.interactionMode, newSession ? .search : .preview)
            XCTAssertEqual(controller.model.searchFocusIsRequested, newSession)
            XCTAssertEqual(controller.model.isPreviewVisible, !newSession)
            controller.cleanup()
        }
    }

    @MainActor
    func testFilterPopoverThenNativeMenuCancellationRoutesTwoNativeReturnsWithSinglePaste() async throws {
        let record = try runtime.appendTestRecord(.text("invoice payload"))
        let controller = prepareMountedController()
        defer { controller.cleanup() }
        controller.model.historyItems = [try XCTUnwrap(runtime.entry(for: record))]
        controller.model.query = "invoice"
        await waitUntil { self.searchField(in: controller.panel?.contentView) != nil }
        controller.enterSearchMode()
        await waitUntil { self.searchField(in: controller.panel?.contentView)?.isEditing == true }
        controller.model.isFilterPopoverPresented = true
        await waitUntil { controller.interactionMode == .modal }
        controller.model.replaceSearchQuery("invoice type:text")
        controller.model.isFilterPopoverPresented = false
        await waitUntil {
            controller.interactionMode == .search
                && self.searchField(in: controller.panel?.contentView)?.isEditing == true
        }
        let field = try XCTUnwrap(searchField(in: controller.panel?.contentView))
        try? await Task.sleep(nanoseconds: 80_000_000)
        let menu = NSMenu(title: "More actions")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        controller.panel?.makeFirstResponder(nil)
        field.coordinator?.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field))
        try? await Task.sleep(nanoseconds: 80_000_000)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        controller.model.presentCreateCategory()
        await waitUntil { controller.interactionMode == .modal }
        controller.model.dismissModal()
        await waitUntil {
            controller.interactionMode == .search
                && self.searchField(in: controller.panel?.contentView)?.isEditing == true
        }
        controller.startMonitors()
        let operation = controller.model.operationGeneration
        let firstReturn = try nativeReturnEvent(controller, timestamp: 0)
        NSApp.postEvent(firstReturn, atStart: true)
        await waitUntil { controller.interactionMode == .picker }
        controller.model.workQueue.sync {}
        MacClippyMainHop.flushCapturedWork()
        XCTAssertEqual(controller.model.query, "invoice type:text")
        XCTAssertEqual(controller.interactionMode, .picker)
        XCTAssertTrue(controller.panel?.isVisible == true)
        XCTAssertEqual(controller.model.focusedItem?.id, record.id)
        XCTAssertEqual(controller.model.operationGeneration, operation)
        XCTAssertEqual(board.string(forType: .string), "unchanged")
        let secondReturn = try nativeReturnEvent(controller, timestamp: 1)
        NSApp.postEvent(secondReturn, atStart: true)
        await waitUntil { self.board.string(forType: .string) == "invoice payload" }
        await waitUntil { controller.panel?.isVisible != true }
        XCTAssertEqual(controller.model.operationGeneration, operation + 2, "One paste followed by session teardown")
    }

    @MainActor
    func testOverlappingPopoverAndReplacedModalPreserveOriginalSearchDestination() async {
        let controller = prepareMountedController()
        defer { controller.cleanup() }
        await waitUntil { self.searchField(in: controller.panel?.contentView) != nil }
        controller.enterSearchMode()
        await waitUntil { self.searchField(in: controller.panel?.contentView)?.isEditing == true }
        controller.model.isFilterPopoverPresented = true
        await waitUntil { controller.interactionMode == .modal }
        controller.model.presentCreateCategory()
        controller.model.isFilterPopoverPresented = false
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.interactionMode, .modal)
        XCTAssertFalse(controller.model.searchFocusIsRequested)
        controller.model.presentCreateCategory()
        try? await Task.sleep(nanoseconds: 100_000_000)
        controller.model.dismissModal()
        await waitUntil {
            controller.interactionMode == .search
                && self.searchField(in: controller.panel?.contentView)?.isEditing == true
        }
    }

    @MainActor
    func testOverlayFromPickerStaysInPickerAndClosedSessionNeverRestoresSearch() async {
        for popover in [false, true] {
            let controller = prepareMountedController()
            await waitUntil { self.searchField(in: controller.panel?.contentView) != nil }
            controller.enterPickerMode()
            if popover { controller.model.isFilterPopoverPresented = true } else {
                controller.model.presentCreateCategory()
            }
            await waitUntil { controller.interactionMode == .modal }
            controller.model.dismissModal()
            await waitUntil { controller.interactionMode == .picker }
            try? await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertFalse(controller.model.searchFocusIsRequested)
            controller.enterSearchMode()
            await waitUntil { self.searchField(in: controller.panel?.contentView)?.isEditing == true }
            if popover { controller.model.isFilterPopoverPresented = true } else {
                controller.model.presentCreateCategory()
            }
            await waitUntil { controller.interactionMode == .modal }
            let session = controller.model.sessionGeneration
            controller.hide()
            try? await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertGreaterThan(controller.model.sessionGeneration, session)
            XCTAssertEqual(controller.interactionMode, .picker)
            XCTAssertFalse(controller.model.searchFocusIsRequested)
            XCTAssertFalse(controller.panel?.isVisible == true)
            controller.cleanup()
        }
    }

    @MainActor
    private func nativeReturnEvent(_ controller: MacClippyDockController, timestamp: TimeInterval) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
            windowNumber: controller.panel?.windowNumber ?? 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }
}
