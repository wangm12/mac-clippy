import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

import MacClippyCore
import MacClippyPlatform


import ApplicationServices
import CoreGraphics

extension MacClippySettingsView {
    func openAccessibilitySettings() {
        if !accessibilityTrusted {
            let options = [
                "AXTrustedCheckOptionPrompt": true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            MacClippyLog.record(
                category: .permission,
                code: .startupFailed,
                operation: "open_accessibility_settings_url",
                recoveryAction: "open_system_settings_manually",
                impact: "permission_settings_unavailable"
            )
            return
        }
        guard NSWorkspace.shared.open(url) else {
            permissionSettingsError = "Unable to open System Settings. Open Privacy & Security manually."
            return
        }
        permissionSettingsError = nil
        refreshPermissionStatus()
    }

    func openInputMonitoringSettings() {
        // Ask macOS to register this app for Input Monitoring before opening
        // the pane. Without this request, MacClippy may be missing from the
        // list entirely and its global Snippet event tap can never start.
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            MacClippyLog.record(
                category: .permission,
                code: .startupFailed,
                operation: "open_input_monitoring_settings_url",
                recoveryAction: "open_system_settings_manually",
                impact: "permission_settings_unavailable"
            )
            return
        }
        guard NSWorkspace.shared.open(url) else {
            permissionSettingsError = "Unable to open System Settings. Open Privacy & Security manually."
            return
        }
        permissionSettingsError = nil
        refreshPermissionStatus()
    }

    func refreshPermissionStatus() {
        let nextAccessibilityTrusted = AXIsProcessTrusted()
        let nextInputMonitoringTrusted = CGPreflightListenEventAccess()
        let didChange = accessibilityTrusted != nextAccessibilityTrusted
            || inputMonitoringTrusted != nextInputMonitoringTrusted

        accessibilityTrusted = nextAccessibilityTrusted
        inputMonitoringTrusted = nextInputMonitoringTrusted

        if didChange {
            (NSApp.delegate as? AppDelegate)?.refreshPermissionDependentFeatures()
        }
    }
}
