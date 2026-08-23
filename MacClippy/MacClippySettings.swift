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
    @State var selectedPage: MacClippySettingsPage? = .general
    @Environment(\.accessibilityReduceMotion) var accessibilityReduceMotion
    @Environment(\.macClippyShouldRegisterSettingsWindow) private var shouldRegisterSettingsWindow

    var reduceMotion: Bool {
        MacClippyMotion.shouldReduceMotion(swiftUI: accessibilityReduceMotion)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPage) {
                ForEach(MacClippySettingsPage.allCases) { page in
                    Label(page.title, systemImage: page.systemImage)
                        .tag(page)
                        .accessibilityIdentifier("macClippy.settings.sidebar.\(page.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(
                min: 180,
                ideal: MacClippySettingsMetrics.sidebarIdealWidth,
                max: 260
            )
        } detail: {
            Form {
                settingsDetail
            }
            .formStyle(.grouped)
            .navigationTitle(selectedPage?.title ?? "Settings")
        }
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

    @ViewBuilder
    var settingsDetail: some View {
        switch selectedPage ?? .general {
        case .general:
            historySection.modifier(MacClippySettingsReveal(index: 0, reduceMotion: reduceMotion))
            shortcutSection.modifier(MacClippySettingsReveal(index: 1, reduceMotion: reduceMotion))
            snippetsSection.modifier(MacClippySettingsReveal(index: 2, reduceMotion: reduceMotion))
            startupSection.modifier(MacClippySettingsReveal(index: 3, reduceMotion: reduceMotion))
            presentationSection.modifier(MacClippySettingsReveal(index: 4, reduceMotion: reduceMotion))
        case .privacy:
            privacySection.modifier(MacClippySettingsReveal(index: 0, reduceMotion: reduceMotion))
        case .permissions:
            permissionsSection.modifier(MacClippySettingsReveal(index: 0, reduceMotion: reduceMotion))
        case .advanced:
            advancedSection.modifier(MacClippySettingsReveal(index: 0, reduceMotion: reduceMotion))
        }
    }

}
