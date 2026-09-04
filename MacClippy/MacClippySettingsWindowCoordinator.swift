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
    private var retiringWindows: [NSWindow] = []
    private var shouldBringRegisteredWindowToFront = false
    private(set) var lastBroughtToFrontWindow: NSWindow?

    func register(_ window: NSWindow) {
        self.window = window
        if let fallbackWindow, fallbackWindow !== window {
            discardFallbackWindow()
        }

        if shouldBringRegisteredWindowToFront {
            shouldBringRegisteredWindowToFront = false
            activateAndBringToFront(window)
        }
    }

    /// Marks that the next registered Settings window should be shown.
    /// Tests use this instead of `bringToFront()` so they do not mount Settings.
    func notePendingBringToFront() {
        shouldBringRegisteredWindowToFront = true
    }

    func bringToFront() {
        notePendingBringToFront()
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
        let hostingView = NSHostingView(rootView: fallbackRootView())
        let fallbackWindow = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: MacClippySettingsMetrics.idealWidth,
                height: MacClippySettingsMetrics.idealHeight
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        fallbackWindow.title = "MacClippy Settings"
        fallbackWindow.animationBehavior = .none
        fallbackWindow.contentView = hostingView
        fallbackWindow.isReleasedWhenClosed = false
        fallbackWindow.delegate = self
        // Fallback NSWindow has no Tahoe toolbar glass. Do not fake it.
        fallbackWindow.minSize = MacClippySettingsMetrics.minSize
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

    private func fallbackRootView() -> AnyView {
        if isRunningUnderXCTest {
            return AnyView(Color.clear)
        }
        return AnyView(
            MacClippySettingsView()
                .environment(\.macClippyShouldRegisterSettingsWindow, false)
        )
    }

    private func discardFallbackWindow() {
        guard let fallbackWindow else { return }
        fallbackWindow.delegate = nil
        fallbackWindow.animationBehavior = .none
        fallbackWindow.contentView = nil
        fallbackHostingView = nil
        fallbackWindow.orderOut(nil)
        fallbackWindow.close()
        retiringWindows.append(fallbackWindow)
        self.fallbackWindow = nil
        DispatchQueue.main.async { [weak self] in
            self?.retiringWindows.removeAll { $0 === fallbackWindow }
        }
    }

    private func activateAndBringToFront(_ window: NSWindow) {
        lastBroughtToFrontWindow = window
        if isRunningUnderXCTest { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeKey()
    }

    private var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return NSClassFromString("XCTestCase") != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCInjectBundleInto"] != nil
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
        window.minSize = MacClippySettingsMetrics.minSize
        window.collectionBehavior.remove([.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle])
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenNone])
        hideSidebarToggle(in: window)
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            self?.hideSidebarToggle(in: window)
        }
        MacClippySettingsWindowCoordinator.shared.register(window)
    }

    func hideSidebarToggle(in window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        let hiddenIDs: Set<NSToolbarItem.Identifier> = [
            .toggleSidebar,
            .sidebarTrackingSeparator,
        ]
        let indices = toolbar.items.enumerated().compactMap { index, item in
            hiddenIDs.contains(item.itemIdentifier) ? index : nil
        }
        for index in indices.reversed() {
            toolbar.removeItem(at: index)
        }
    }
}

struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsConfigurationView { SettingsConfigurationView() }

    func updateNSView(_ nsView: SettingsConfigurationView, context: Context) {
        nsView.applyWindowConfiguration()
    }
}
