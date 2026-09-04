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
    static let macClippyIgnoreNextCopyRequested = Notification.Name("macClippyIgnoreNextCopyRequested")
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
    @AppStorage(MacClippyRetentionPreferences.pauseDurationSecondsKey)
    var pauseDurationSeconds = MacClippyTimedPauseDuration.fiveMinutes.rawValue
    @AppStorage(MacClippyRetentionPreferences.captureAllKey)
    var captureAll = false
    @AppStorage(MacClippyRetentionPreferences.launchAtLoginKey)
    var launchAtLogin = false
    @AppStorage(MacClippyRetentionPreferences.alwaysPastePlainTextKey)
    var alwaysPastePlainText = false
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
    @State var storageUsage: MacClippyStorageUsage?
    @State var isRepairingSearchIndex = false
    @State var isExportingDiagnostics = false
    @State var isCreatingBackup = false
    @State var isRestoringBackup = false
    @State var isRestoreBackupConfirmationPresented = false
    @State var diagnosticsMessage: String?
    @State var diagnosticsMessageIsError = false
    @State var isDeleteHistoryConfirmationPresented = false
    @State var isDeletingHistory = false
    @State var isCompressingImages = false
    @State var imageCompressMessage: String?
    @State var imageCompressMessageIsError = false
    @State var historyDeletionMessage: String?
    @State var historyDeletionMessageIsError = false
    @State var isPrivacyNoticePresented = false
    @State var isCaptureRulesExpanded = false
    @State var selectedPage: MacClippySettingsPage? = .general
    @Environment(\.accessibilityReduceMotion) var accessibilityReduceMotion
    @Environment(\.macClippyShouldRegisterSettingsWindow) private var shouldRegisterSettingsWindow

    var reduceMotion: Bool {
        MacClippyMotion.shouldReduceMotion(swiftUI: accessibilityReduceMotion)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selectedPage) {
                ForEach(MacClippySettingsPage.allCases) { page in
                    Label(page.title, systemImage: page.systemImage)
                        .font(.body)
                        .padding(.vertical, 5)
                        .tag(page)
                        .accessibilityIdentifier("macClippy.settings.sidebar.\(page.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 36)
            .navigationTitle("Settings")
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(
                min: MacClippySettingsMetrics.sidebarMinWidth,
                ideal: MacClippySettingsMetrics.sidebarIdealWidth,
                max: MacClippySettingsMetrics.sidebarMaxWidth
            )
        } detail: {
            Form {
                settingsDetail
            }
            .formStyle(.grouped)
            .navigationTitle(selectedPage?.title ?? "Settings")
            .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .frame(
            minWidth: MacClippySettingsMetrics.minWidth,
            idealWidth: MacClippySettingsMetrics.idealWidth,
            minHeight: MacClippySettingsMetrics.minHeight,
            idealHeight: MacClippySettingsMetrics.idealHeight
        )
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
            refreshStorageUsage()
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
            "Replace local data with a backup?",
            isPresented: $isRestoreBackupConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Choose Backup…", role: .destructive) {
                chooseBackupToRestore()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces history, pinboards, and snippets on this Mac with the chosen backup.")
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

    @ViewBuilder
    var settingsDetail: some View {
        switch selectedPage ?? .general {
        case .general:
            historySection.modifier(MacClippySettingsReveal(index: 0, reduceMotion: reduceMotion))
            shortcutSection.modifier(MacClippySettingsReveal(index: 1, reduceMotion: reduceMotion))
            pasteSection.modifier(MacClippySettingsReveal(index: 2, reduceMotion: reduceMotion))
            snippetsSection.modifier(MacClippySettingsReveal(index: 3, reduceMotion: reduceMotion))
            startupSection.modifier(MacClippySettingsReveal(index: 4, reduceMotion: reduceMotion))
            presentationSection.modifier(MacClippySettingsReveal(index: 5, reduceMotion: reduceMotion))
        case .privacy:
            privacySection.modifier(MacClippySettingsReveal(index: 0, reduceMotion: reduceMotion))
        case .permissions:
            permissionsSection.modifier(MacClippySettingsReveal(index: 0, reduceMotion: reduceMotion))
        case .advanced:
            advancedSection.modifier(MacClippySettingsReveal(index: 0, reduceMotion: reduceMotion))
        }
    }

}
