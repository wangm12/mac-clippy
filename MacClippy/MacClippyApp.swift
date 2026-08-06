import AppKit
import ServiceManagement
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
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let launchAtLogin = LaunchAtLoginLifecycle()
    private lazy var clipboardHotKey = MacClippyGlobalHotKey(
        descriptor: .load(from: .standard),
        callback: { [weak self] in
            self?.dockController?.toggle()
        }
    )
    private var runtime: MacClippyRuntime?
    private var dockController: MacClippyDockController?
    private var bundledApplicationIcon: NSImage?
    private var didStart = false
    private var hotKeyDescriptorObserver: NSObjectProtocol?
    private var hotKeyRecordingObserver: NSObjectProtocol?
    private var presentationPreferencesObserver: NSObjectProtocol?
    private var isHotKeyRecording = false
    private var hotKeyWasRegisteredBeforeRecording = false
    private var registeredHotKeyDescriptor = MacClippyGlobalHotKeyDescriptor.load(from: .standard)
    private var privacyAlert: NSAlert?

    func applicationDidFinishLaunching(_ notification: Notification) {
        observeHotKeyDescriptorChanges()
        observeHotKeyRecordingChanges()
        observePresentationPreferencesChanges()
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
        clipboardHotKey.unregister()
        dockController?.cleanup()
        dockController = nil
        runtime?.stop()
        runtime = nil
        launchAtLogin.stop()
        privacyAlert = nil
        statusItem = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        openSettingsWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard didStart, !isHotKeyRecording else { return }
        refreshPermissionDependentFeatures()

        // Recreate the Carbon registration after the app returns from System
        // Settings. This gives a revoked/restored Input Monitoring grant a
        // chance to recover without requiring a full relaunch.
        clipboardHotKey.unregister()
        do {
            try clipboardHotKey.register()
        } catch {
            MacClippyLog.record(
                category: .hotkey,
                code: .hotkeyRegistrationFailed,
                operation: "global_hotkey_activation_retry",
                recoveryAction: "open_input_monitoring_settings",
                impact: "global_hotkey_unavailable"
            )
        }
    }

    func refreshPermissionDependentFeatures() {
        runtime?.refreshPermissionDependentFeatures()
    }

    private func start() throws {
        guard !didStart else { return }

        applyDockIconVisibility()
        if !shouldHideFromMenuBar {
            try ensureStatusItem()
        }

        do {
            let runtime = try MacClippyRuntime()
            runtime.start()
            self.runtime = runtime
            registeredHotKeyDescriptor = .load(from: .standard)
            dockController = MacClippyDockController(runtime: runtime)
            launchAtLogin.prepare()
            do {
                try launchAtLogin.setEnabled(UserDefaults.standard.bool(forKey: MacClippyRetentionPreferences.launchAtLoginKey))
            } catch {
                MacClippyLog.record(
                    category: .lifecycle,
                    code: .launchAtLoginUpdateFailed,
                    operation: "launch_at_login_startup_sync",
                    recoveryAction: "check_system_settings",
                    impact: "app_continues_without_launch_at_login_change"
                )
            }
            try clipboardHotKey.register()
            didStart = true
            // Do not enter a synchronous nested modal loop directly from
            // applicationDidFinishLaunching. The app is not fully inside its
            // normal event loop at this point, which can leave an NSAlert
            // visible but unable to dispatch button clicks.
            DispatchQueue.main.async { [weak self] in
                self?.presentPrivacyNoticeIfNeeded()
            }
        } catch {
            clipboardHotKey.unregister()
            runtime?.stop()
            runtime = nil
            launchAtLogin.stop()
            throw error
        }
    }

    private func presentPrivacyNoticeIfNeeded() {
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

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        guard opened else {
            MacClippySettingsWindowCoordinator.shared.bringToFront()
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
            clipboardHotKey.unregister()
            return
        }

        let shouldRestore = MacClippyHotKeyRecordingPolicy.shouldRestoreHotKey(
            wasRegisteredBeforeRecording: hotKeyWasRegisteredBeforeRecording,
            didStart: didStart,
            isCurrentlyRegistered: clipboardHotKey.isRegistered
        )
        isHotKeyRecording = false
        hotKeyWasRegisteredBeforeRecording = false

        guard shouldRestore else { return }
        do {
            try clipboardHotKey.register()
        } catch {
            MacClippyLog.record(
                category: .hotkey,
                code: .hotkeyRegistrationFailed,
                operation: "global_hotkey_recording_restore",
                recoveryAction: "retry_hotkey_registration",
                impact: "global_hotkey_unavailable"
            )
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

    private var shouldHideFromMenuBar: Bool {
        UserDefaults.standard.bool(forKey: MacClippyPresentationPreferences.hideFromMenuBarKey)
    }

    private var shouldHideDockIcon: Bool {
        UserDefaults.standard.bool(forKey: MacClippyPresentationPreferences.hideDockIconKey)
    }

    private func applyPresentationPreferences() {
        applyDockIconVisibility()
        if shouldHideFromMenuBar {
            removeStatusItem()
        } else {
            try? ensureStatusItem()
        }
    }

    private func applyDockIconVisibility() {
        let policy = MacClippyPresentationPolicy.activationPolicy(hideDockIcon: shouldHideDockIcon)
        guard NSApp.activationPolicy() != policy else { return }
        _ = NSApp.setActivationPolicy(policy)
    }

    private func ensureStatusItem() throws {
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

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    func refreshStorageHealth(completion: @escaping ([String: MacClippyDatabaseHealthReport]) -> Void) {
        guard let runtime else {
            completion([:])
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let health = runtime.storageHealth()
            DispatchQueue.main.async {
                completion(health)
            }
        }
    }

    func exportDiagnostics(to url: URL) throws {
        let snapshot = runtime?.diagnosticsStorageSnapshot()
        try MacClippyDiagnosticsExporter.export(to: url, storageSnapshot: snapshot)
    }

    func repairSearchIndex(completion: @escaping (Result<MacClippySearchRepairReport, Error>) -> Void) {
        guard let runtime else {
            completion(.failure(StartupError.runtimeUnavailable))
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try runtime.repairSearchIndex() }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func deleteUnpinnedHistory(completion: @escaping (Result<MacClippyBatchDeleteResult, Error>) -> Void) {
        guard let runtime else {
            completion(.failure(StartupError.runtimeUnavailable))
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try runtime.deleteUnpinnedHistory() }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func configureStatusItem(_ button: NSStatusBarButton) {
        button.title = ""
        button.image = (bundledApplicationIcon?.copy() as? NSImage)
            ?? NSImage(named: NSImage.applicationIconName)
        button.image?.size = NSSize(width: 18, height: 18)
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.toolTip = "Mac Clippy"
        button.target = self
        button.action = #selector(toggleDock(_:))
    }

    private func loadBundledApplicationIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    @objc private func toggleDock(_ sender: Any?) {
        dockController?.toggle()
    }

    private func handleStartupFailure(_: Error) {
        MacClippyLog.record(
            category: .lifecycle,
            code: .startupFailed,
            operation: "application_startup",
            recoveryAction: "retry_startup",
            impact: "menu_bar_runtime_unavailable"
        )
        clipboardHotKey.unregister()

        let alert = NSAlert()
        alert.messageText = "Mac Clippy could not start"
        alert.informativeText = "Mac Clippy could not initialize its local services. Retry now or close the app and try again."
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            retryStartup()
        }
    }

    private func retryStartup() {
        do {
            try start()
        } catch {
            handleStartupFailure(error)
        }
    }
}

private enum StartupError: LocalizedError {
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

        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

private enum LaunchAtLoginError: Error {
    case notReady
}
