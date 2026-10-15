import AppKit
import MacClippyCore
import MacClippyPlatform

@MainActor
extension AppDelegate {
    func observePresentationPreferencesChanges() {
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

    var shouldHideFromMenuBar: Bool {
        settingsDefaultsProvider.defaults?.bool(forKey: MacClippyPresentationPreferences.hideFromMenuBarKey) ?? false
    }

    var shouldHideDockIcon: Bool {
        settingsDefaultsProvider.defaults?.bool(forKey: MacClippyPresentationPreferences.hideDockIconKey) ?? false
    }

    func applyPresentationPreferences() {
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

    func applyDockIconVisibility(
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

    func openSettingsWindow() {
#if MACCLIPPY_E2E
        MacClippyE2EUIInteractionProbe.shared.mark("settings-request")
#endif
        NSApp.activate(ignoringOtherApps: true)
        let coordinator = MacClippySettingsWindowCoordinator.shared
        coordinator.configureDefaultsProvider(settingsDefaultsProvider)
        coordinator.bringToFront()
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
