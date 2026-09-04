import AppKit
import Foundation

import MacClippyCore
import MacClippyPlatform

extension AppDelegate {
    private var isRunningUnderXCTest: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCInjectBundleInto"] != nil { return true }
        return Bundle.allBundles.contains { bundle in
            bundle.bundlePath.contains("XCTest") || bundle.bundlePath.hasSuffix(".xctest")
        }
    }

    func activateDiagnosticsJournal() {
        guard !isRunningUnderXCTest else { return }
        do {
            let paths = try MacClippyPaths()
            MacClippyDiagnosticsJournal.shared.activate(url: paths.diagnosticsJournalURL)
        } catch {
            MacClippyLog.record(
                category: .lifecycle,
                code: .startupFailed,
                operation: "diagnostics_journal_activate",
                recoveryAction: "export_uses_in_memory_events",
                impact: "diagnostics_do_not_survive_quit"
            )
        }
    }

    func startDisplayLifecycleMonitoring() {
        guard !isRunningUnderXCTest else { return }
        displayLifecycleCoordinator.handler = { [weak self] event in
            self?.handleDisplayLifecycleEvent(event)
        }
        displayLifecycleCoordinator.start()
    }

    func handleDisplayLifecycleEvent(_ event: MacClippyDisplayLifecycleEvent) {
        guard !isRunningUnderXCTest else { return }
        runtime?.noteDisplayLifecycleForCapture(event)
        if MacClippyDisplayGenerationPolicy.shouldRecreateStatusItem(for: event) {
            recreateStatusItemIfPresented()
        }
        dockController?.noteDisplayLifecycleEvent(event)
    }

    func recreateStatusItemIfPresented() {
        let presentationState = MacClippyPresentationPolicy.state(
            hideFromMenuBar: UserDefaults.standard.bool(forKey: MacClippyPresentationPreferences.hideFromMenuBarKey),
            hideDockIcon: UserDefaults.standard.bool(forKey: MacClippyPresentationPreferences.hideDockIconKey)
        )
        guard presentationState.showsMenuBarIcon else { return }
        removeStatusItem()
        do {
            try ensureStatusItem()
        } catch {
            MacClippyLog.record(
                category: .lifecycle,
                code: .startupFailed,
                operation: "status_item_display_recreate",
                recoveryAction: "retry_status_item_creation",
                impact: "menu_bar_entry_unavailable"
            )
        }
    }
}
