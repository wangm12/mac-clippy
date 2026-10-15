import AppKit
import XCTest

@testable import MacClippy

final class MacClippyChromeHitTargetTests: XCTestCase {
    @MainActor
    func testDockCannotCaptureControlClicksForWindowDragging() {
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 1_024, height: 360))
        defer { panel.close() }
        XCTAssertFalse(panel.isMovable, "The bottom dock must not capture control clicks for window dragging")
        XCTAssertFalse(panel.isMovableByWindowBackground)
    }

    @MainActor
    func testNativeClickHarnessDeliversOneClickToAppKit() async throws {
        let target = ChromeClickTarget()
        let button = NSButton(frame: NSRect(x: 32, y: 22, width: 36, height: 36))
        button.title = "Test"
        button.target = target
        button.action = #selector(ChromeClickTarget.clicked)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 80))
        content.addSubview(button)
        let window = MacClippyDockPanel(contentRect: NSRect(x: 100, y: 100, width: 100, height: 80))
        window.contentView = content
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let ready = await waitUntil { NSApp.isActive && window.isKeyWindow }
        guard ready else { return XCTFail("Native control did not become ready for mouse input") }
        try await sendClick(to: window, at: NSPoint(x: 50, y: 40))
        let received = await waitUntil { target.clicks == 1 }
        XCTAssertTrue(received, "AppKit did not receive exactly one action from one mouse down/up pair")
    }

    @MainActor
    private func sendClick(to window: NSWindow, at point: NSPoint) async throws {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let eventNumber = Int(timestamp * 1_000_000) & 0x7FFF_FFFE
        var deliveredDowns = 0
        // AppKit 26 can reconstitute a posted mouse-down with screen coordinates
        // in locationInWindow (even NSButton then misses it). Normalize only our
        // dedicated fixture window's mouse-down after dequeue, retaining the
        // requested point. AppKit can also replace the synthetic event number.
        let monitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDown) { event in
                var normalized = event
                MainActor.assumeIsolated {
                    guard event.windowNumber == window.windowNumber else { return }
                    deliveredDowns += 1
                    normalized = NSEvent.mouseEvent(
                        with: event.type, location: point, modifierFlags: event.modifierFlags,
                        timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil,
                        eventNumber: event.eventNumber, clickCount: 1, pressure: event.pressure) ?? event
                }
                return normalized
            })
        defer { NSEvent.removeMonitor(monitor) }
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let isRelease = type == .leftMouseUp
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: eventNumber + (isRelease ? 1 : 0), clickCount: 1, pressure: isRelease ? 0 : 1))
            // Posting only to this application preserves AppKit tracking and
            // currentEvent without moving the system pointer or posting globally.
            NSApp.postEvent(event, atStart: false)
        }
        let deliveredDown = await waitUntil { deliveredDowns == 1 }
        XCTAssertTrue(deliveredDown, "One mouse-down must traverse AppKit's native queue exactly once")
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<150 {
            MacClippyMainHop.flushCapturedWork()
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return predicate()
    }
}

@MainActor
private final class ChromeClickTarget: NSObject {
    var clicks = 0
    @objc func clicked() { clicks += 1 }
}
