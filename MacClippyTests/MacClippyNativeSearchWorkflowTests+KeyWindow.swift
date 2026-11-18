import AppKit
import MacClippyCore
import XCTest

@testable import MacClippy

extension MacClippyNativeSearchWorkflowTests {
    @MainActor
    func testInstalledResignKeyObserverPreservesAccessibilityDetailsHandoff() async throws {
        let record = try runtime.appendTestRecord(.text("editable payload"))
        let controller = prepareMountedController()
        defer { controller.cleanup() }
        controller.model.historyItems = [try XCTUnwrap(runtime.entry(for: record))]
        controller.model.replaceSearchQuery("editable type:text")
        await waitUntil { self.searchField(in: controller.panel?.contentView) != nil }
        controller.enterSearchMode()
        await waitUntil { self.searchField(in: controller.panel?.contentView)?.isEditing == true }
        controller.startMonitors()
        controller.showCardDetails(id: record.id, editing: true)
        await waitUntil { controller.detailsEditing == .content }
        let dock = try XCTUnwrap(controller.panel)
        let details = try XCTUnwrap(controller.detailsPanel)
        XCTAssertTrue(details.isKeyWindow)
        controller.handlePanelDidResignKey(
            dock, monitorGeneration: controller.monitorGeneration,
            pointerLocation: CGPoint(x: -1_000, y: -1_000))
        XCTAssertTrue(dock.isVisible)
        XCTAssertTrue(details.isVisible)
        XCTAssertEqual(controller.detailsEditSession?.contentDraft, "editable payload")
        XCTAssertEqual(controller.model.query, "editable type:text")
        XCTAssertEqual(board.string(forType: .string), "unchanged")
        // A real outside-click path still dismisses both unchanged surfaces.
        controller.closeIfOutside(at: CGPoint(x: -1_000, y: -1_000))
        XCTAssertFalse(dock.isVisible)
        XCTAssertFalse(details.isVisible)
    }

    @MainActor
    func testQueuedResignKeyNotificationCannotDismissPanelAfterItRegainsKey() async throws {
        let controller = prepareMountedController()
        defer { controller.cleanup() }
        let dock = try XCTUnwrap(controller.panel)
        controller.startMonitors()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: dock)
        dock.makeKey()
        XCTAssertTrue(dock.isKeyWindow)
        MacClippyMainHop.flushCapturedWork()
        controller.handlePanelDidResignKey(
            dock, monitorGeneration: controller.monitorGeneration,
            pointerLocation: CGPoint(x: -1_000, y: -1_000))
        XCTAssertTrue(dock.isVisible)
        XCTAssertTrue(dock.isKeyWindow)
        XCTAssertEqual(board.string(forType: .string), "unchanged")
    }
}
