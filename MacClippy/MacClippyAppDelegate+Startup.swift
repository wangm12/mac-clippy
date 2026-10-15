import AppKit
import Darwin
import Foundation

import MacClippyCore
import MacClippyPlatform

@MainActor
extension AppDelegate {
    func start(allowPendingRestore: Bool = false) throws {
        guard !didStart else { return }
        let presentationState = MacClippyPresentationPolicy.state(
            hideFromMenuBar: shouldHideFromMenuBar,
            hideDockIcon: shouldHideDockIcon
        )
        try configureStartupPresentation(presentationState)
        do {
            let runtime = try makeRuntimeForStartup(allowPendingRestore: allowPendingRestore)
            runtime.start()
            self.runtime = runtime
            finishStartup(with: runtime)
        } catch {
            rollbackStartup()
            throw error
        }
    }

    private func finishStartup(with runtime: MacClippyRuntime) {
        registeredHotKeyDescriptor = .load(from: runtime.preferencesDefaults)
        MacClippySettingsWindowCoordinator.shared.configureDefaultsProvider(settingsDefaultsProvider)
        dockController = MacClippyDockController(
            runtime: runtime,
            defaults: runtime.preferencesDefaults,
            onOpenSettings: { [weak self] in self?.openSettingsWindowFromDock() }
        )
        dockController?.statusItemScreenFrame = { [weak self] in
            Self.statusItemScreenFrame(for: self?.statusItem?.button)
        }
#if MACCLIPPY_E2E
        dockController?.pasteTargetApplication = NSRunningApplication.current
#endif
        configureStartupFeatures()
        didStart = true
        DispatchQueue.main.async { [weak self] in
            self?.activateDiagnosticsJournal()
            self?.startDisplayLifecycleMonitoring()
            self?.presentPrivacyNoticeIfNeeded()
        }
    }

    private func configureStartupPresentation(_ state: MacClippyPresentationPolicy.State) throws {
        if isIsolatedE2E {
#if MACCLIPPY_E2E
            NSApp.setActivationPolicy(.accessory)
#endif
        } else {
            applyDockIconVisibility(state.activationPolicy)
            if state.showsMenuBarIcon {
                try ensureStatusItem()
            }
        }
    }

    private func configureStartupFeatures() {
        guard !isIsolatedE2E else { return }
        launchAtLogin.prepare()
        updateLaunchAtLoginFromPreferences()
        registerStartupHotKeys()
    }

    private func updateLaunchAtLoginFromPreferences() {
        do {
            let enabled = UserDefaults.standard.bool(forKey: MacClippyRetentionPreferences.launchAtLoginKey)
            try launchAtLogin.setEnabled(enabled)
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
    }

    private func registerStartupHotKeys() {
        do {
            try clipboardHotKey.register()
            UserDefaults.standard.removeObject(forKey: MacClippyHotKeyStatus.errorKey)
        } catch {
            recordHotKeyRegistrationFailure(operation: "global_hotkey_startup", error: error)
            restoreDockRecoveryPathIfNeeded()
        }
        registerSecondaryHotKey(ignoreNextCopyHotKey, role: .ignoreNextCopy)
    }

    func recoverPendingRestoreAndStart() {
        guard !startupRecoveryInProgress else { return }
        startupRecoveryInProgress = true
        let generation = maintenanceGeneration
        let paths: MacClippyPaths
        do {
            paths = try startupStoragePaths()
        } catch {
            startupRecoveryInProgress = false
            handleStartupFailure(error)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let recovery = Result {
                try MacClippyBackup.recoverPendingRestore(at: paths.rootURL)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.maintenanceGeneration == generation else { return }
                self.startupRecoveryInProgress = false
                do {
                    try recovery.get()
                    try self.start(allowPendingRestore: true)
                } catch {
                    self.handleStartupFailure(error)
                }
            }
        }
    }

    func rollbackStartup() {
        maintenanceGeneration &+= 1
        displayLifecycleCoordinator.stop()
        if !isIsolatedE2E {
            clipboardHotKey.unregister()
            ignoreNextCopyHotKey.unregister()
        }
        dockController?.cleanup()
        dockController = nil
        runtime?.stop()
        runtime = nil
        if !isIsolatedE2E {
            launchAtLogin.stop()
        }
        removeStatusItem()
        didStart = false
    }

    private func presentPrivacyNoticeIfNeeded() {
        // XCTest launches the app as a host before it injects the test
        // bundle. A synchronous first-run alert would block that handshake
        // indefinitely in a clean test environment. The privacy notice is
        // still exercised by its policy tests and remains unchanged for real
        // user launches.
        guard !isLaunchedByXCTest, !isIsolatedE2E else { return }
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

    func startupStoragePaths() throws -> MacClippyPaths {
#if MACCLIPPY_E2E
        guard let e2eIsolation else { throw MacClippyE2EIsolationError.invalidConfiguration }
        return e2eIsolation.paths
#else
        return try MacClippyPaths()
#endif
    }

}

final class LaunchAtLoginLifecycle {
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
