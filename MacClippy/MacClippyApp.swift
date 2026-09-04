import AppKit
import SwiftUI

import MacClippyCore
import MacClippyPlatform

@main
struct MacClippyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            MacClippySettingsView()
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

private enum MacClippyHotKeyStatus {
    static let errorKey = "com.macallyouneed.macclippy.hotKey.registrationError"
    static let unavailableMessage = "Mac Clippy could not register the global shortcut. Check Input Monitoring or choose a different shortcut, then try again."
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let launchAtLogin = LaunchAtLoginLifecycle()
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
    private var didStart = false
    private var hotKeyDescriptorObserver: NSObjectProtocol?
    private var hotKeyRecordingObserver: NSObjectProtocol?
    private var presentationPreferencesObserver: NSObjectProtocol?
    private var ignoreNextCopyObserver: NSObjectProtocol?
    private var isHotKeyRecording = false
    private var hotKeyWasRegisteredBeforeRecording = false
    private var ignoreNextWasRegisteredBeforeRecording = false
    private var registeredHotKeyDescriptor = MacClippyGlobalHotKeyDescriptor.load(from: .standard)
    private var privacyAlert: NSAlert?
    var maintenanceGeneration: UInt = 0
    let displayLifecycleCoordinator = MacClippyDisplayLifecycleCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        observeHotKeyDescriptorChanges()
        observeHotKeyRecordingChanges()
        observePresentationPreferencesChanges()
        observeIgnoreNextCopyRequests()
        bundledApplicationIcon = loadBundledApplicationIcon()
        if let bundledApplicationIcon {
            NSApp.applicationIconImage = bundledApplicationIcon
        }

        do {
            try start()
        } catch {
            handleStartupFailure(error)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyDescriptorObserver {
            NotificationCenter.default.removeObserver(hotKeyDescriptorObserver)
            self.hotKeyDescriptorObserver = nil
        }
        if let hotKeyRecordingObserver {
            NotificationCenter.default.removeObserver(hotKeyRecordingObserver)
            self.hotKeyRecordingObserver = nil
        }
        if let presentationPreferencesObserver {
            NotificationCenter.default.removeObserver(presentationPreferencesObserver)
            self.presentationPreferencesObserver = nil
        }
        if let ignoreNextCopyObserver {
            NotificationCenter.default.removeObserver(ignoreNextCopyObserver)
            self.ignoreNextCopyObserver = nil
        }
        displayLifecycleCoordinator.stop()
        rollbackStartup()
        privacyAlert = nil
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard didStart, !isHotKeyRecording else { return }
        refreshPermissionDependentFeatures()

        // Recreate the Carbon registration after the app returns from System
        // Settings. This gives a revoked/restored Input Monitoring grant a
        // chance to recover without requiring a full relaunch.
        clipboardHotKey.unregister()
        ignoreNextCopyHotKey.unregister()
        do {
            try clipboardHotKey.register()
            UserDefaults.standard.removeObject(forKey: MacClippyHotKeyStatus.errorKey)
        } catch {
            recordHotKeyRegistrationFailure(operation: "global_hotkey_activation_retry", error: error)
            restoreDockRecoveryPathIfNeeded()
        }
        registerSecondaryHotKey(ignoreNextCopyHotKey, role: .ignoreNextCopy)
    }

    func start() throws {
        guard !didStart else { return }

        let presentationState = MacClippyPresentationPolicy.state(
            hideFromMenuBar: shouldHideFromMenuBar,
            hideDockIcon: shouldHideDockIcon
        )
        applyDockIconVisibility(presentationState.activationPolicy)
        if presentationState.showsMenuBarIcon {
            try ensureStatusItem()
        }

        do {
            let runtime = try MacClippyRuntime()
            runtime.start()
            self.runtime = runtime
            registeredHotKeyDescriptor = .load(from: .standard)
            dockController = MacClippyDockController(runtime: runtime)
            dockController?.statusItemScreenFrame = { [weak self] in
                Self.statusItemScreenFrame(for: self?.statusItem?.button)
            }
            launchAtLogin.prepare()
            do {
                try launchAtLogin.setEnabled(UserDefaults.standard.bool(forKey: MacClippyRetentionPreferences.launchAtLoginKey))
            } catch MacClippyLaunchAtLoginRegistration.Error.debugBuildRefused {
                // Debug and DerivedData copies must not become a second login item.
            } catch {
                MacClippyLog.record(
                    category: .lifecycle,
                    code: .launchAtLoginUpdateFailed,
                    operation: "launch_at_login_startup_sync",
                    recoveryAction: "check_system_settings",
                    impact: "app_continues_without_launch_at_login_change"
                )
            }
            do {
                try clipboardHotKey.register()
                UserDefaults.standard.removeObject(forKey: MacClippyHotKeyStatus.errorKey)
            } catch {
                recordHotKeyRegistrationFailure(operation: "global_hotkey_startup", error: error)
                restoreDockRecoveryPathIfNeeded()
            }
            registerSecondaryHotKey(ignoreNextCopyHotKey, role: .ignoreNextCopy)
            didStart = true
            // Do not enter a synchronous nested modal loop directly from
            // applicationDidFinishLaunching. The app is not fully inside its
            // normal event loop at this point, which can leave an NSAlert
            // visible but unable to dispatch button clicks.
            DispatchQueue.main.async { [weak self] in
                self?.activateDiagnosticsJournal()
                self?.startDisplayLifecycleMonitoring()
                self?.presentPrivacyNoticeIfNeeded()
            }
        } catch {
            rollbackStartup()
            throw error
        }
    }

    func rollbackStartup() {
        maintenanceGeneration &+= 1
        displayLifecycleCoordinator.stop()
        clipboardHotKey.unregister()
        ignoreNextCopyHotKey.unregister()
        dockController?.cleanup()
        dockController = nil
        runtime?.stop()
        runtime = nil
        launchAtLogin.stop()
        removeStatusItem()
        didStart = false
    }

    private func presentPrivacyNoticeIfNeeded() {
        // XCTest launches the app as a host before it injects the test
        // bundle. A synchronous first-run alert would block that handshake
        // indefinitely in a clean test environment. The privacy notice is
        // still exercised by its policy tests and remains unchanged for real
        // user launches.
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] == nil,
              environment["XCInjectBundleInto"] == nil else { return }
        guard MacClippyPrivacyNoticePolicy.shouldPresent() else { return }

        let alert = NSAlert()
        alert.messageText = MacClippyPrivacyNoticePolicy.title
        alert.informativeText = MacClippyPrivacyNoticePolicy.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Open Settings")
        alert.window.level = .floating
        privacyAlert = alert

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        privacyAlert = nil
        MacClippyPrivacyNoticePolicy.acknowledge()
        if response == .alertSecondButtonReturn {
            openSettingsWindow()
        }
    }

    func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        MacClippySettingsWindowCoordinator.shared.bringToFront()
        let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        guard opened else {
            return
        }
        // SwiftUI creates the Settings window asynchronously. Bring it to
        // the front after the scene has had a chance to materialize.
        DispatchQueue.main.async {
            MacClippySettingsWindowCoordinator.shared.bringToFront()
        }
    }

    private func observeHotKeyDescriptorChanges() {
        hotKeyDescriptorObserver = NotificationCenter.default.addObserver(
            forName: .macClippyHotKeyDescriptorChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let descriptor = MacClippyGlobalHotKeyDescriptor.load(from: .standard)
                    try self.clipboardHotKey.update(to: descriptor)
                    self.registeredHotKeyDescriptor = descriptor
                    UserDefaults.standard.removeObject(forKey: MacClippyHotKeyStatus.errorKey)
                    NotificationCenter.default.post(name: .macClippyHotKeyUpdateSucceeded, object: nil)
                } catch {
                    let previousDescriptor = self.registeredHotKeyDescriptor
                    MacClippyGlobalHotKeyDescriptor.save(previousDescriptor, to: .standard)
                    let message: String
                    if case MacClippyGlobalHotKeyError.registrationRollbackFailed = error {
                        message = "Could not update the global shortcut, and the previous shortcut could not be restored. Check Input Monitoring and try again."
                    } else {
                        message = "Could not update the global shortcut. The previous shortcut was restored."
                    }
                    MacClippyLog.record(
                        category: .hotkey,
                        code: .hotkeyRegistrationFailed,
                        operation: "global_hotkey_update",
                        recoveryAction: "retry_hotkey_registration",
                        impact: "global_hotkey_unavailable"
                    )
                    UserDefaults.standard.set(message, forKey: MacClippyHotKeyStatus.errorKey)
                    NotificationCenter.default.post(
                        name: .macClippyHotKeyUpdateFailed,
                        object: nil,
                        userInfo: [
                            NSLocalizedDescriptionKey: message,
                            MacClippyHotKeyNotificationUserInfo.descriptor: previousDescriptor
                        ]
                    )
                }
            }
        }
    }

    private func observeHotKeyRecordingChanges() {
        hotKeyRecordingObserver = NotificationCenter.default.addObserver(
            forName: .macClippyHotKeyRecordingChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let isActive = notification.userInfo?[MacClippyHotKeyNotificationUserInfo.isActive] as? Bool else {
                return
            }
            MainActor.assumeIsolated {
                self?.handleHotKeyRecordingChanged(isActive)
            }
        }
    }

    private func handleHotKeyRecordingChanged(_ isActive: Bool) {
        if isActive {
            guard !isHotKeyRecording else { return }
            isHotKeyRecording = true
            hotKeyWasRegisteredBeforeRecording = clipboardHotKey.isRegistered
            ignoreNextWasRegisteredBeforeRecording = ignoreNextCopyHotKey.isRegistered
            clipboardHotKey.unregister()
            ignoreNextCopyHotKey.unregister()
            return
        }

        let shouldRestore = MacClippyHotKeyRecordingPolicy.shouldRestoreHotKey(
            wasRegisteredBeforeRecording: hotKeyWasRegisteredBeforeRecording,
            didStart: didStart,
            isCurrentlyRegistered: clipboardHotKey.isRegistered
        )
        let shouldRestoreIgnoreNext = MacClippyHotKeyRecordingPolicy.shouldRestoreSecondaryHotKey(
            wasRegisteredBeforeRecording: ignoreNextWasRegisteredBeforeRecording,
            didStart: didStart
        )
        isHotKeyRecording = false
        hotKeyWasRegisteredBeforeRecording = false
        ignoreNextWasRegisteredBeforeRecording = false

        if shouldRestore {
            do {
                try clipboardHotKey.register()
                UserDefaults.standard.removeObject(forKey: MacClippyHotKeyStatus.errorKey)
            } catch {
                recordHotKeyRegistrationFailure(operation: "global_hotkey_recording_restore", error: error)
                restoreDockRecoveryPathIfNeeded()
            }
        }
        if shouldRestoreIgnoreNext {
            registerSecondaryHotKey(ignoreNextCopyHotKey, role: .ignoreNextCopy)
        }
    }

    private func observePresentationPreferencesChanges() {
        presentationPreferencesObserver = NotificationCenter.default.addObserver(
            forName: .macClippyPresentationPreferencesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyPresentationPreferences()
            }
        }
    }

    private func observeIgnoreNextCopyRequests() {
        ignoreNextCopyObserver = NotificationCenter.default.addObserver(
            forName: .macClippyIgnoreNextCopyRequested,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runtime?.ignoreNextCopy()
            }
        }
    }

    private var shouldHideFromMenuBar: Bool {
        UserDefaults.standard.bool(forKey: MacClippyPresentationPreferences.hideFromMenuBarKey)
    }

    private var shouldHideDockIcon: Bool {
        UserDefaults.standard.bool(forKey: MacClippyPresentationPreferences.hideDockIconKey)
    }

    private func registerSecondaryHotKey(
        _ hotKey: MacClippyGlobalHotKey,
        role: MacClippyGlobalHotKeyRole
    ) {
        do {
            try hotKey.register()
        } catch {
            let operation = MacClippyHotKeyRegistrationPolicy.registrationFailureOperation(for: role)
            if MacClippyHotKeyRegistrationPolicy.shouldSurfaceSharedRegistrationBanner(for: role) {
                recordHotKeyRegistrationFailure(operation: operation, error: error)
            } else {
                MacClippyLog.record(
                    category: .hotkey,
                    code: .hotkeyRegistrationFailed,
                    operation: operation,
                    recoveryAction: "check_input_monitoring_or_change_hotkey",
                    impact: "ignore_next_copy_hotkey_unavailable"
                )
            }
        }
    }

    func recordHotKeyRegistrationFailure(operation: String, error: Error? = nil) {
        let rollbackFailed: Bool
        if let hotKeyError = error as? MacClippyGlobalHotKeyError {
            if case .registrationRollbackFailed = hotKeyError {
                rollbackFailed = true
            } else {
                rollbackFailed = false
            }
        } else {
            rollbackFailed = false
        }
        let message = rollbackFailed
            ? "Mac Clippy could not update the global shortcut and could not restore the previous shortcut. Open Settings and choose a new shortcut."
            : MacClippyHotKeyStatus.unavailableMessage
        let recoveryAction = rollbackFailed
            ? "open_hotkey_settings"
            : "check_input_monitoring_or_change_hotkey"
        UserDefaults.standard.set(message, forKey: MacClippyHotKeyStatus.errorKey)
        MacClippyLog.record(
            category: .hotkey,
            code: .hotkeyRegistrationFailed,
            operation: operation,
            recoveryAction: recoveryAction,
            impact: "global_hotkey_unavailable"
        )
        NotificationCenter.default.post(
            name: .macClippyHotKeyUpdateFailed,
            object: nil,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                MacClippyHotKeyNotificationUserInfo.descriptor: registeredHotKeyDescriptor
            ]
        )
    }

    private func restoreDockRecoveryPathIfNeeded() {
        guard shouldHideFromMenuBar && shouldHideDockIcon else { return }
        UserDefaults.standard.set(false, forKey: MacClippyPresentationPreferences.hideDockIconKey)
        NotificationCenter.default.post(name: .macClippyPresentationPreferencesChanged, object: nil)
        applyPresentationPreferences()
    }

    private func applyPresentationPreferences() {
        let state = MacClippyPresentationPolicy.state(
            hideFromMenuBar: shouldHideFromMenuBar,
            hideDockIcon: shouldHideDockIcon
        )
        applyDockIconVisibility(state.activationPolicy)
        if !state.showsMenuBarIcon {
            removeStatusItem()
        } else {
            do {
                try ensureStatusItem()
            } catch {
                MacClippyLog.record(
                    category: .lifecycle,
                    code: .startupFailed,
                    operation: "status_item_preference_update",
                    recoveryAction: "retry_status_item_creation",
                    impact: "menu_bar_entry_unavailable"
                )
            }
        }
    }

    private func applyDockIconVisibility(
        _ policy: NSApplication.ActivationPolicy
    ) {
        guard NSApp.activationPolicy() != policy else { return }
        guard NSApp.setActivationPolicy(policy) else {
            MacClippyLog.record(
                category: .lifecycle,
                code: .startupFailed,
                operation: "activation_policy_update",
                recoveryAction: "retry_presentation_preferences",
                impact: "dock_visibility_unavailable"
            )
            return
        }
    }

    func ensureStatusItem() throws {
        if let button = statusItem?.button {
            configureStatusItem(button)
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            NSStatusBar.system.removeStatusItem(item)
            throw StartupError.statusItemUnavailable
        }
        statusItem = item
        configureStatusItem(button)
    }

    func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    @objc func toggleDock(_ sender: Any?) {
        dockController?.toggle(source: .statusItem)
    }

    static func statusItemScreenFrame(for button: NSStatusBarButton?) -> CGRect? {
        guard let button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
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

private final class LaunchAtLoginLifecycle {
    private(set) var isReady = false

    func prepare() {
        isReady = true
    }

    func stop() {
        isReady = false
    }

    func setEnabled(_ enabled: Bool) throws {
        guard isReady else { throw LaunchAtLoginError.notReady }

        try MacClippyLaunchAtLoginRegistration.setEnabled(enabled)
    }
}

private enum LaunchAtLoginError: Error {
    case notReady
}
