import AppKit
import XCTest

@testable import MacClippy

extension MacClippySettingsTests {
    @MainActor
    func testClosedFallbackSettingsWindowIsReused() throws {
        let coordinator = MacClippySettingsWindowCoordinator()
        coordinator.bringToFront()
        let firstWindow = try XCTUnwrap(coordinator.lastBroughtToFrontWindow)
        defer { firstWindow.close() }
        firstWindow.close()

        coordinator.bringToFront()

        XCTAssertIdentical(coordinator.lastBroughtToFrontWindow, firstWindow,
                           "Reopening Settings must reuse its form and window")
    }

    @MainActor
    func testRegisteredSettingsSceneIsReusedForDirectRequests() {
        let coordinator = MacClippySettingsWindowCoordinator()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        coordinator.register(window)
        coordinator.bringToFront()

        XCTAssertIdentical(coordinator.lastBroughtToFrontWindow, window)
    }
}
