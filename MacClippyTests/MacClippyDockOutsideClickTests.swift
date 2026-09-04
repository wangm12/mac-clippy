import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippyDockOutsideClickTests: XCTestCase {
    func testOutsideClickDismissalWinsOverKeyOwnershipRestoration() {
        let panelFrame = CGRect(x: 0, y: 0, width: 800, height: 360)
        let outside = CGPoint(x: 900, y: 200)

        XCTAssertTrue(
            MacClippyDockOutsideClickPolicy.shouldDismiss(
                panelFrame: panelFrame,
                clickLocation: outside,
                isInsideExcludedWindow: false,
                ignoreUntil: .distantPast,
                now: Date()
            )
        )
        XCTAssertFalse(
            MacClippyDockOutsideClickPolicy.shouldDismiss(
                panelFrame: panelFrame,
                clickLocation: outside,
                isInsideExcludedWindow: true,
                ignoreUntil: .distantPast,
                now: Date()
            )
        )
        XCTAssertFalse(
            MacClippyDockOutsideClickPolicy.shouldDismiss(
                panelFrame: panelFrame,
                clickLocation: outside,
                isInsideExcludedWindow: false,
                isInsideStatusItem: true,
                ignoreUntil: .distantPast,
                now: Date()
            )
        )
    }

    @MainActor
    func testPanelKeyLossClosesVisibleDockForOutsidePointer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyDockOutsideClickTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: root))
        let controller = MacClippyDockController(runtime: runtime)
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 360))
        controller.panel = panel
        controller.swiftUIReduceMotion = true
        panel.orderFrontRegardless()
        defer { controller.cleanup() }

        XCTAssertTrue(panel.isVisible)
        controller.handlePanelDidResignKey(
            panel,
            monitorGeneration: controller.monitorGeneration,
            pointerLocation: CGPoint(x: 900, y: 200)
        )

        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(controller.isClosing)
    }

    @MainActor
    func testStatusItemClickDoesNotCountAsAnOutsideDismiss() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyDockStatusItemClickTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: root))
        let controller = MacClippyDockController(runtime: runtime)
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 360))
        controller.panel = panel
        controller.swiftUIReduceMotion = true
        controller.statusItemScreenFrame = { CGRect(x: 880, y: 180, width: 40, height: 40) }
        panel.orderFrontRegardless()
        defer { controller.cleanup() }

        controller.handlePanelDidResignKey(
            panel,
            monitorGeneration: controller.monitorGeneration,
            pointerLocation: CGPoint(x: 900, y: 200)
        )

        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(controller.isClosing)
    }

    @MainActor
    func testStatusItemToggleDuringHideDoesNotFlashThePanelBackOpen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyDockStatusItemToggleTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: root))
        let controller = MacClippyDockController(runtime: runtime)
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 360))
        controller.panel = panel
        controller.swiftUIReduceMotion = false
        panel.orderFrontRegardless()
        defer { controller.cleanup() }

        controller.hide()
        XCTAssertTrue(controller.isClosing)
        XCTAssertTrue(panel.isVisible)

        controller.toggle(source: .statusItem)

        XCTAssertTrue(controller.isClosing)
        XCTAssertTrue(panel.isVisible)
    }
}
