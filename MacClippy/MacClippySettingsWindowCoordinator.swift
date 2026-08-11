import AppKit
import SwiftUI

private struct MacClippySettingsWindowRegistrationKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var macClippyShouldRegisterSettingsWindow: Bool {
        get { self[MacClippySettingsWindowRegistrationKey.self] }
        set { self[MacClippySettingsWindowRegistrationKey.self] = newValue }
    }
}

@MainActor
final class MacClippySettingsWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = MacClippySettingsWindowCoordinator()

    private weak var window: NSWindow?
    private var fallbackWindow: NSWindow?
    private var fallbackHostingView: NSView?
    private var shouldBringRegisteredWindowToFront = false

    func register(_ window: NSWindow) {
        self.window = window
        if let fallbackWindow, fallbackWindow !== window {
            fallbackWindow.delegate = nil
            fallbackWindow.orderOut(nil)
            fallbackWindow.close()
            self.fallbackHostingView = nil
            self.fallbackWindow = nil
        }

        if shouldBringRegisteredWindowToFront {
            shouldBringRegisteredWindowToFront = false
            activateAndBringToFront(window)
        }
    }

    func bringToFront() {
        shouldBringRegisteredWindowToFront = true
        if let window {
            shouldBringRegisteredWindowToFront = false
            activateAndBringToFront(window)
            return
        }
        if let fallbackWindow {
            activateAndBringToFront(fallbackWindow)
            return
        }
        presentFallbackWindow()
    }

    private func presentFallbackWindow() {
        let hostingView = NSHostingView(
            rootView: MacClippySettingsView()
                .environment(\.macClippyShouldRegisterSettingsWindow, false)
        )
        let fallbackWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        fallbackWindow.title = "MacClippy Settings"
        fallbackWindow.contentView = hostingView
        fallbackWindow.isReleasedWhenClosed = false
        fallbackWindow.delegate = self
        fallbackWindow.minSize = NSSize(width: 560, height: 520)
        fallbackWindow.level = .normal
        fallbackWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        self.fallbackHostingView = hostingView
        self.fallbackWindow = fallbackWindow
        fallbackWindow.center()
        activateAndBringToFront(fallbackWindow)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow,
              closedWindow === fallbackWindow else { return }
        fallbackHostingView = nil
        fallbackWindow = nil
    }

    private func activateAndBringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeKey()
    }
}

/// Re-applies regular-window behavior whenever SwiftUI creates or re-hydrates
/// the native Settings scene window. It deliberately does not join Spaces or
/// overlay another app's full-screen window.
final class SettingsConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowConfiguration()
    }

    func applyWindowConfiguration() {
        guard let window else { return }
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.title = "MacClippy Settings"
        window.styleMask.insert([.titled, .closable, .resizable])
        window.minSize = NSSize(width: 560, height: 520)
        window.collectionBehavior.remove([.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle])
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenNone])
        MacClippySettingsWindowCoordinator.shared.register(window)
    }
}

struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsConfigurationView { SettingsConfigurationView() }

    func updateNSView(_ nsView: SettingsConfigurationView, context: Context) {
        nsView.applyWindowConfiguration()
    }
}
