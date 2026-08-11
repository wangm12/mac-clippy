import ApplicationServices
import AppKit
import CoreGraphics
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

import MacClippyCore
import MacClippyPlatform

extension Notification.Name {
    static let macClippyHotKeyDescriptorChanged = Notification.Name("macClippyHotKeyDescriptorChanged")
    static let macClippyHotKeyRecordingChanged = Notification.Name("macClippyHotKeyRecordingChanged")
    static let macClippyHotKeyRecordingEvent = Notification.Name("macClippyHotKeyRecordingEvent")
    static let macClippyHotKeyUpdateFailed = Notification.Name("macClippyHotKeyUpdateFailed")
    static let macClippyHotKeyUpdateSucceeded = Notification.Name("macClippyHotKeyUpdateSucceeded")
    static let macClippyPresentationPreferencesChanged = Notification.Name("macClippyPresentationPreferencesChanged")
}

enum MacClippyHotKeyNotificationUserInfo {
    static let descriptor = "descriptor"
    static let isActive = "isActive"
    static let keyCode = "keyCode"
    static let modifierFlags = "modifierFlags"
}

struct MacClippySettingsView: View {
    @AppStorage(MacClippyRetentionPreferences.maxAgeDaysKey)
    var maxAgeDays = MacClippyRetentionPreferences.defaultMaxAgeDays
    @AppStorage(MacClippyRetentionPreferences.excludeConcealedKey)
    var excludeConcealed = true
    @AppStorage(MacClippyRetentionPreferences.excludeTransientKey)
    var excludeTransient = true
    @AppStorage(MacClippyRetentionPreferences.excludedAppsKey)
    var excludedApps = ""
    @AppStorage(MacClippyRetentionPreferences.excludedTextPatternsKey)
    var excludedTextPatterns = ""
    @AppStorage(MacClippyRetentionPreferences.privacyPauseKey)
    var privacyPause = false
    @AppStorage(MacClippyRetentionPreferences.captureAllKey)
    var captureAll = false
    @AppStorage(MacClippyRetentionPreferences.launchAtLoginKey)
    var launchAtLogin = false
    @AppStorage(MacClippyPresentationPreferences.hideFromMenuBarKey)
    var hideFromMenuBar = false
    @AppStorage(MacClippyPresentationPreferences.hideDockIconKey)
    var hideDockIcon = false
    @AppStorage(MacClippySnippetExpansionSettings.modeKey)
    var snippetExpansionMode = MacClippySnippetExpansionSettings.defaultMode.rawValue

    @State var accessibilityTrusted = AXIsProcessTrusted()
    @State var inputMonitoringTrusted = CGPreflightListenEventAccess()
    @State var permissionSettingsError: String?
    @State var launchAtLoginError: String?
    @State var hotKeyDescriptor = MacClippyGlobalHotKeyDescriptor.load(from: .standard)
    @State var hotKeyError: String?
    @State var storageHealth: [String: MacClippyDatabaseHealthReport] = [:]
    @State var isRepairingSearchIndex = false
    @State var isExportingDiagnostics = false
    @State var diagnosticsMessage: String?
    @State var diagnosticsMessageIsError = false
    @State var isDeleteHistoryConfirmationPresented = false
    @State var isDeletingHistory = false
    @State var historyDeletionMessage: String?
    @State var historyDeletionMessageIsError = false
    @State var isPrivacyNoticePresented = false
    @State var isCaptureRulesExpanded = false
    @State var isAdvancedExpanded = false
    @Environment(\.accessibilityReduceMotion) var accessibilityReduceMotion
    @Environment(\.macClippyShouldRegisterSettingsWindow) private var shouldRegisterSettingsWindow

    var reduceMotion: Bool {
        MacClippyMotion.shouldReduceMotion(swiftUI: accessibilityReduceMotion)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsHeader.modifier(MacClippySettingsReveal(index: 0, reduceMotion: reduceMotion))
                historySection.modifier(MacClippySettingsReveal(index: 1, reduceMotion: reduceMotion))
                shortcutSection.modifier(MacClippySettingsReveal(index: 2, reduceMotion: reduceMotion))
                snippetsSection.modifier(MacClippySettingsReveal(index: 3, reduceMotion: reduceMotion))
                permissionsSection.modifier(MacClippySettingsReveal(index: 4, reduceMotion: reduceMotion))
                startupSection.modifier(MacClippySettingsReveal(index: 5, reduceMotion: reduceMotion))
                presentationSection.modifier(MacClippySettingsReveal(index: 6, reduceMotion: reduceMotion))
                privacySection.modifier(MacClippySettingsReveal(index: 7, reduceMotion: reduceMotion))
                advancedSection.modifier(MacClippySettingsReveal(index: 8, reduceMotion: reduceMotion))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Keep a comfortable initial size without pinning the content to a
        // fixed viewport. A resizable window and larger system text need the
        // scroll view to be able to adapt instead of clipping controls.
        .frame(minWidth: 560, idealWidth: 700, minHeight: 520, idealHeight: 760)
        .background {
            if shouldRegisterSettingsWindow {
                SettingsWindowConfigurator()
            }
        }
        .onAppear {
            maxAgeDays = MacClippyHistoryCapacity(maxAgeDays: maxAgeDays).maxAgeDays
            refreshPermissionStatus()
            launchAtLogin = SMAppService.mainApp.status == .enabled
            hotKeyError = UserDefaults.standard.string(forKey: "com.macallyouneed.macclippy.hotKey.registrationError")
            refreshStorageHealth()
        }
        .onChange(of: hideFromMenuBar) { _, _ in
            notifyPresentationPreferencesChanged()
        }
        .onChange(of: hideDockIcon) { _, _ in
            notifyPresentationPreferencesChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPermissionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macClippyHotKeyUpdateFailed)) { notification in
            hotKeyError = notification.userInfo?[NSLocalizedDescriptionKey] as? String
            hotKeyDescriptor = (notification.userInfo?[MacClippyHotKeyNotificationUserInfo.descriptor] as? MacClippyGlobalHotKeyDescriptor)
                ?? MacClippyGlobalHotKeyDescriptor.load(from: .standard)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macClippyHotKeyUpdateSucceeded)) { _ in
            hotKeyError = nil
            UserDefaults.standard.removeObject(forKey: "com.macallyouneed.macclippy.hotKey.registrationError")
        }
        .confirmationDialog(
            "Delete unpinned history?",
            isPresented: $isDeleteHistoryConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete Unpinned History", role: .destructive) {
                deleteUnpinnedHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes unpinned clipboard items, their search entries, OCR text, and associated blobs. Pinned items stay.")
        }
        .sheet(isPresented: $isPrivacyNoticePresented) {
            MacClippyPrivacyNoticeView()
        }
    }

}
