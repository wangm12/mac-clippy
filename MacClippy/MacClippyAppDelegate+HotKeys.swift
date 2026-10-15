import AppKit
import MacClippyCore
import MacClippyPlatform

enum MacClippyHotKeyStatus {
    static let errorKey = "com.macallyouneed.macclippy.hotKey.registrationError"
    static let unavailableMessage = "Mac Clippy could not register the global shortcut. "
        + "Check Input Monitoring or choose a different shortcut, then try again."
}

@MainActor
extension AppDelegate {
    func observeHotKeyDescriptorChanges() {
        hotKeyDescriptorObserver = NotificationCenter.default.addObserver(
            forName: .macClippyHotKeyDescriptorChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isIsolatedE2E else { return }
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
                        message = "Could not update the global shortcut, and the previous shortcut could not be "
                            + "restored. Check Input Monitoring and try again."
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

    func observeHotKeyRecordingChanges() {
        hotKeyRecordingObserver = NotificationCenter.default.addObserver(
            forName: .macClippyHotKeyRecordingChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let isActive = notification.userInfo?[MacClippyHotKeyNotificationUserInfo.isActive] as? Bool else {
                return
            }
            MainActor.assumeIsolated {
                guard let self, !self.isIsolatedE2E else { return }
                self.handleHotKeyRecordingChanged(isActive)
            }
        }
    }

    private func handleHotKeyRecordingChanged(_ isActive: Bool) {
        guard !isIsolatedE2E else { return }
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

    func registerSecondaryHotKey(
        _ hotKey: MacClippyGlobalHotKey,
        role: MacClippyGlobalHotKeyRole
    ) {
        guard !isIsolatedE2E else { return }
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
            ? "Mac Clippy could not update the global shortcut and could not restore the previous shortcut. "
                + "Open Settings and choose a new shortcut."
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

    func restoreDockRecoveryPathIfNeeded() {
        guard shouldHideFromMenuBar && shouldHideDockIcon else { return }
        UserDefaults.standard.set(false, forKey: MacClippyPresentationPreferences.hideDockIconKey)
        NotificationCenter.default.post(name: .macClippyPresentationPreferencesChanged, object: nil)
        applyPresentationPreferences()
    }

    func observeIgnoreNextCopyRequests() {
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

}
