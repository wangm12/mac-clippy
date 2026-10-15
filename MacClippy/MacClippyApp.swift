import AppKit
import SwiftUI

import MacClippyCore
import MacClippyPlatform

@main
struct MacClippyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            MacClippySettingsDefaultsHost(provider: appDelegate.settingsDefaultsProvider)
        }
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Show Clipboard History") { appDelegate.dockController?.show() }
            }
            CommandGroup(replacing: .help) {
                Button("Shortcuts & Search Help…") {
                    if let controller = appDelegate.dockController { controller.openHelpAfterHide() } else {
                        MacClippyHelpWindow.shared.present()
                    }
                }
            }
        }
    }
}

enum MacClippyHotKeyRecordingPolicy {
    static func shouldRestoreHotKey(
        wasRegisteredBeforeRecording: Bool,
        didStart: Bool,
        isCurrentlyRegistered: Bool
    ) -> Bool {
        wasRegisteredBeforeRecording && didStart && !isCurrentlyRegistered
    }

    static func shouldRestoreSecondaryHotKey(
        wasRegisteredBeforeRecording: Bool,
        didStart: Bool
    ) -> Bool {
        wasRegisteredBeforeRecording && didStart
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    let settingsDefaultsProvider = MacClippySettingsDefaultsProvider()
    let launchAtLogin = LaunchAtLoginLifecycle()
    lazy var clipboardHotKey = MacClippyGlobalHotKey(
        descriptor: .load(from: .standard),
        callback: { [weak self] in
            self?.dockController?.toggle(source: .hotKey)
        }
    )
    lazy var ignoreNextCopyHotKey = MacClippyGlobalHotKey(
        descriptor: .load(from: .standard, role: .ignoreNextCopy),
        role: .ignoreNextCopy,
        callback: { [weak self] in
            self?.runtime?.ignoreNextCopy()
        }
    )
    var runtime: MacClippyRuntime?
    var dockController: MacClippyDockController?
    var bundledApplicationIcon: NSImage?
    var didStart = false
    var hotKeyDescriptorObserver: NSObjectProtocol?
    var hotKeyRecordingObserver: NSObjectProtocol?
    var presentationPreferencesObserver: NSObjectProtocol?
    var ignoreNextCopyObserver: NSObjectProtocol?
    var isHotKeyRecording = false
    var hotKeyWasRegisteredBeforeRecording = false
    var ignoreNextWasRegisteredBeforeRecording = false
    var startupRecoveryInProgress = false
    lazy var registeredHotKeyDescriptor = MacClippyGlobalHotKeyDescriptor.load(from: .standard)
    var privacyAlert: NSAlert?
    var maintenanceGeneration: UInt = 0
    let displayLifecycleCoordinator = MacClippyDisplayLifecycleCoordinator()
#if MACCLIPPY_E2E
    var e2eIsolation: MacClippyE2EIsolation?
    var e2eRecipient: MacClippyE2ERecipient?
    var e2ePasteBarrier: MacClippyE2EPasteBarrier?
    var e2eControlServer: MacClippyE2EControlServer?
#endif

    var isIsolatedE2E: Bool {
#if MACCLIPPY_E2E
        true
#else
        false
#endif
    }
}

enum StartupError: LocalizedError {
    case statusItemUnavailable
    case runtimeUnavailable

    var errorDescription: String? {
        switch self {
        case .statusItemUnavailable:
            return "The menu bar status item could not be created."
        case .runtimeUnavailable:
            return "Mac Clippy is not running."
        }
    }
}
