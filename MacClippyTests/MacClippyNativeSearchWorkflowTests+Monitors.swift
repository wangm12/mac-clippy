import AppKit
import MacClippyPlatform
import XCTest

@testable import MacClippy

extension MacClippyNativeSearchWorkflowTests {
    @MainActor
    func testInstalledKeyMonitorConsumesEscapeBeforeDetailsNativeResponder() async throws {
        let record = try runtime.appendTestRecord(.text("draft"))
        let controller = prepareMountedController()
        defer { controller.cleanup() }
        controller.showDetails(editing: .content, targetID: record.id)
        await waitUntil { controller.detailsEditing == .content }
        let panel = try XCTUnwrap(controller.detailsPanel)
        let spy = MacClippyNativeKeySpyView(frame: panel.contentView?.frame ?? .zero)
        panel.contentView = spy
        panel.makeKeyAndOrderFront(nil)
        XCTAssertTrue(panel.makeFirstResponder(spy))
        controller.startMonitors()
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.postEvent(event, atStart: true)
        await waitUntil { controller.detailsEditing == .none || !spy.keyCodes.isEmpty }
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(controller.detailsEditing, .none)
        XCTAssertEqual(controller.interactionMode, .details)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(spy.keyCodes.isEmpty, "The already handled Escape must not reach native Close")
        XCTAssertEqual(board.string(forType: .string), "unchanged")
    }
}

private final class MacClippyNativeKeySpyView: NSView {
    var keyCodes: [UInt16] = []

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        keyCodes.append(event.keyCode)
    }
}
