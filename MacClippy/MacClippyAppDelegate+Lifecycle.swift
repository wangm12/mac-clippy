import AppKit
import Darwin
import Foundation

import MacClippyCore
import MacClippyPlatform

@MainActor
extension AppDelegate {
    var isLaunchedByXCTest: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCInjectBundleInto"] != nil
    }

    private var hasValidBuildIdentity: Bool {
#if MACCLIPPY_E2E
        let e2eFlagEnabled = true
#else
        let e2eFlagEnabled = false
#endif
        return MacClippyE2EBuildIdentity.allowsStartup(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            e2eFlagEnabled: e2eFlagEnabled
        )
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard hasValidBuildIdentity else {
            refuseStartupForBuildIdentityMismatch()
            return
        }
#if !MACCLIPPY_E2E
        settingsDefaultsProvider.install(.standard)
#endif
#if MACCLIPPY_E2E
        // Keep background ingestion out of the Dock. Visible UI measurements
        // activate this isolated instance explicitly through the control path.
        NSApp.setActivationPolicy(.accessory)
#endif
        guard isLaunchedByXCTest, !isIsolatedE2E else { return }
        UserDefaults.standard.register(defaults: [
            "NSAutomaticWindowAnimationsEnabled": false,
            "NSDisableAutomaticWindowAnimations": true
        ])
        NSWindow.allowsAutomaticWindowTabbing = false
        MacClippyMainHop.setCaptureForTesting(true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard hasValidBuildIdentity else {
            refuseStartupForBuildIdentityMismatch()
            return
        }
        guard !isLaunchedByXCTest || isIsolatedE2E else { return }
#if MACCLIPPY_E2E
        do {
            let isolation = try MacClippyE2EIsolation()
            settingsDefaultsProvider.install(isolation.defaults)
            let recipient = MacClippyE2ERecipient()
            let pasteBarrier = MacClippyE2EPasteBarrier()
            let controlServer = try MacClippyE2EControlServer(rootURL: isolation.rootURL)
            try controlServer.start { [weak self] request, acceptedAt in
                guard let self else {
                    return MacClippyE2EControlResponse(ok: false, errorCode: "application-unavailable")
                }
                return await self.handleE2EControlRequest(request, acceptedAt: acceptedAt)
            }
            e2eIsolation = isolation
            e2eRecipient = recipient
            e2ePasteBarrier = pasteBarrier
            e2eControlServer = controlServer
        } catch {
            fputs("MACCLIPPY_E2E startup refused: \(error)\n", stderr)
            NSApp.terminate(nil)
            return
        }
#endif
        observeHotKeyDescriptorChanges()
        observeHotKeyRecordingChanges()
        observePresentationPreferencesChanges()
        observeIgnoreNextCopyRequests()
        bundledApplicationIcon = loadBundledApplicationIcon()
        if let bundledApplicationIcon {
            NSApp.applicationIconImage = bundledApplicationIcon
        }

        recoverPendingRestoreAndStart()
    }

    func refuseStartupForBuildIdentityMismatch() {
        fputs("MacClippy startup refused: bundle ID and MACCLIPPY_E2E build flag do not match.\n", stderr)
        NSApp.terminate(nil)
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
#if MACCLIPPY_E2E
        e2eControlServer?.stop()
        e2eControlServer = nil
#endif
        rollbackStartup()
#if MACCLIPPY_E2E
        e2eIsolation?.disposePerRunDefaultsDomain()
#endif
        privacyAlert = nil
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard didStart, !isHotKeyRecording else { return }
        refreshPermissionDependentFeatures()
        guard !isIsolatedE2E else { return }

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

}
