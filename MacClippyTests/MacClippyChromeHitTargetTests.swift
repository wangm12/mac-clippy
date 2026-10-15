import AppKit
import SwiftUI
import XCTest

@testable import MacClippy

final class MacClippyChromeHitTargetTests: XCTestCase {
    @MainActor
    func testVisibleChromeCircleRespondsAtCenterAndEdges() async throws {
        for symbol in ["line.3.horizontal.decrease", "gearshape"] {
            var clicks = 0
            let host = NSHostingView(rootView: ChromeFixture(symbol: symbol) { clicks += 1 })
            let window = MacClippyDockPanel(contentRect: NSRect(x: 100, y: 100, width: 100, height: 80))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)

            // These points are inside the visible 36pt circle, but outside
            // the SF Symbol's painted pixels. Testing only its center misses
            // the dead area of a plain Button with an unshaped image label.
            let offsets: [NSPoint] = [.zero, .init(x: -14, y: 0), .init(x: 14, y: 0),
                                      .init(x: 0, y: -14), .init(x: 0, y: 14)]
            for (index, offset) in offsets.enumerated() {
                let point = NSPoint(x: 50 + offset.x, y: 40 + offset.y)
                try sendClick(to: window, at: point)
                try await Task.sleep(nanoseconds: 30_000_000)
                XCTAssertEqual(clicks, index + 1, "One click at \(offset) must activate \(symbol)")
            }
        }
    }

    @MainActor
    private func sendClick(to window: NSWindow, at point: NSPoint) throws {
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }
}

private struct ChromeFixture: View {
    let symbol: String
    let action: () -> Void
    @Namespace private var namespace

    var body: some View {
        MacClippyGlassContainer {
            MacClippyDockChromeIconButton(
                systemImage: symbol, glassID: "test", namespace: namespace,
                reduceMotion: true, highContrast: false,
                accessibilityLabel: "Test", accessibilityIdentifier: "test", help: "Test", action: action)
        }
        .frame(width: 100, height: 80)
    }
}
