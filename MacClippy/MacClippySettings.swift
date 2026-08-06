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

enum MacClippyRetentionPreferences {
    static let maxItemsKey = "com.macallyouneed.macclippy.retention.maxItems"
    static let maxAgeDaysKey = "com.macallyouneed.macclippy.retention.maxAgeDays"
    static let maxImageMegabytesKey = "com.macallyouneed.macclippy.retention.maxImageMegabytes"
    static let maxHistoryMegabytesKey = "com.macallyouneed.macclippy.retention.maxHistoryMegabytes"
    static let captureAllKey = "com.macallyouneed.macclippy.capture.captureAll"
    static let excludeConcealedKey = "com.macallyouneed.macclippy.capture.excludeConcealed"
    static let excludeTransientKey = "com.macallyouneed.macclippy.capture.excludeTransient"
    static let excludedAppsKey = "com.macallyouneed.macclippy.capture.excludedApps"
    static let excludedTextPatternsKey = "com.macallyouneed.macclippy.capture.excludedTextPatterns"
    static let privacyPauseKey = "com.macallyouneed.macclippy.capture.privacyPause"
    static let launchAtLoginKey = "com.macallyouneed.macclippy.launchAtLogin"

    static let defaultMaxItems = 10_000
    static let defaultMaxAgeDays = 0
    static let defaultMaxImageMegabytes = 2_048
    static let defaultMaxHistoryMegabytes = MacClippyPasteboardInputLimits.default.maxHistoryBytes / (1_024 * 1_024)

    static func policy(from defaults: UserDefaults = .standard) -> RetentionPolicy {
        let maxItems = defaults.object(forKey: maxItemsKey) as? Int ?? defaultMaxItems
        let maxAgeDays = defaults.object(forKey: maxAgeDaysKey) as? Int ?? defaultMaxAgeDays
        let maxImageMegabytes = defaults.object(forKey: maxImageMegabytesKey) as? Int ?? defaultMaxImageMegabytes
        let maxHistoryMegabytes = defaults.object(forKey: maxHistoryMegabytesKey) as? Int ?? defaultMaxHistoryMegabytes
        let configuredHistoryBytes = maxHistoryMegabytes > 0 ? maxHistoryMegabytes * 1_024 * 1_024 : 0
        let maxHistoryBytes = configuredHistoryBytes > 0
            ? min(configuredHistoryBytes, MacClippyPasteboardInputLimits.default.maxHistoryBytes)
            : nil
        return RetentionPolicy(
            maxItems: maxItems > 0 ? maxItems : nil,
            maxAge: maxAgeDays > 0 ? TimeInterval(maxAgeDays) * 86_400 : nil,
            maxImageBytes: maxImageMegabytes > 0 ? maxImageMegabytes * 1_024 * 1_024 : nil,
            maxTotalBytes: maxHistoryBytes
        )
    }

    static func exclusionRules(from defaults: UserDefaults = .standard) -> CaptureExclusionRules {
        let userExcludedApps = Set(
            defaults.string(forKey: excludedAppsKey)?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty } ?? []
        )
        let excludedApps = CaptureExclusionRules.defaultExcludedAppBundleIDs.union(userExcludedApps)
        let excludedTextPatterns = (defaults.string(forKey: excludedTextPatternsKey) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hasConcealedPreference = defaults.object(forKey: excludeConcealedKey) != nil
        let hasTransientPreference = defaults.object(forKey: excludeTransientKey) != nil
        return CaptureExclusionRules(
            concealedPasteboardTypes: hasConcealedPreference
                ? (defaults.bool(forKey: excludeConcealedKey) ? ["org.nspasteboard.ConcealedType"] : [])
                : CaptureExclusionRules.defaultConcealedPasteboardTypes,
            transientPasteboardTypes: hasTransientPreference
                ? (defaults.bool(forKey: excludeTransientKey) ? ["org.nspasteboard.TransientType"] : [])
                : CaptureExclusionRules.defaultTransientPasteboardTypes,
            excludedAppBundleIDs: excludedApps,
            excludedTextPatterns: excludedTextPatterns,
            captureAll: defaults.bool(forKey: captureAllKey)
        )
    }
}

enum MacClippyPresentationPreferences {
    static let hideFromMenuBarKey = "com.macallyouneed.macclippy.presentation.hideFromMenuBar"
    static let hideDockIconKey = "com.macallyouneed.macclippy.presentation.hideDockIcon"
}

enum MacClippyPresentationPolicy {
    static func activationPolicy(hideDockIcon: Bool) -> NSApplication.ActivationPolicy {
        hideDockIcon ? .accessory : .regular
    }
}

enum MacClippyHistoryCapacity: Int, CaseIterable {
    case day
    case week
    case month
    case unlimited

    var maxAgeDays: Int {
        switch self {
        case .day: 1
        case .week: 7
        case .month: 30
        case .unlimited: 0
        }
    }

    var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        case .unlimited: "Unlimited"
        }
    }

    var index: Double { Double(rawValue) }

    init(maxAgeDays: Int) {
        self = Self.allCases.min {
            let distance = abs($0.maxAgeDays - maxAgeDays)
            let otherDistance = abs($1.maxAgeDays - maxAgeDays)
            return distance < otherDistance || (distance == otherDistance && $0.rawValue < $1.rawValue)
        } ?? .unlimited
    }

    init(index: Double) {
        let rounded = Int(index.rounded())
        self = Self(rawValue: min(max(rounded, 0), Self.allCases.count - 1)) ?? .unlimited
    }
}

struct MacClippySettingsView: View {
    @AppStorage(MacClippyRetentionPreferences.maxAgeDaysKey)
    private var maxAgeDays = MacClippyRetentionPreferences.defaultMaxAgeDays
    @AppStorage(MacClippyRetentionPreferences.excludeConcealedKey)
    private var excludeConcealed = true
    @AppStorage(MacClippyRetentionPreferences.excludeTransientKey)
    private var excludeTransient = true
    @AppStorage(MacClippyRetentionPreferences.excludedAppsKey)
    private var excludedApps = ""
    @AppStorage(MacClippyRetentionPreferences.excludedTextPatternsKey)
    private var excludedTextPatterns = ""
    @AppStorage(MacClippyRetentionPreferences.privacyPauseKey)
    private var privacyPause = false
    @AppStorage(MacClippyRetentionPreferences.captureAllKey)
    private var captureAll = false
    @AppStorage(MacClippyRetentionPreferences.launchAtLoginKey)
    private var launchAtLogin = false
    @AppStorage(MacClippyPresentationPreferences.hideFromMenuBarKey)
    private var hideFromMenuBar = false
    @AppStorage(MacClippyPresentationPreferences.hideDockIconKey)
    private var hideDockIcon = false
    @AppStorage(MacClippySnippetExpansionSettings.modeKey)
    private var snippetExpansionMode = MacClippySnippetExpansionSettings.defaultMode.rawValue

    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var inputMonitoringTrusted = CGPreflightListenEventAccess()
    @State private var launchAtLoginError: String?
    @State private var hotKeyDescriptor = MacClippyGlobalHotKeyDescriptor.load(from: .standard)
    @State private var hotKeyError: String?
    @State private var storageHealth: [String: MacClippyDatabaseHealthReport] = [:]
    @State private var isRepairingSearchIndex = false
    @State private var diagnosticsMessage: String?
    @State private var diagnosticsMessageIsError = false
    @State private var isDeleteHistoryConfirmationPresented = false
    @State private var isDeletingHistory = false
    @State private var historyDeletionMessage: String?
    @State private var historyDeletionMessageIsError = false
    @State private var isPrivacyNoticePresented = false
    @State private var isCaptureRulesExpanded = false
    @State private var isAdvancedExpanded = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    private let permissionRefreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var reduceMotion: Bool {
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
        .frame(width: 700, height: 760)
        .background(SettingsWindowConfigurator())
        .onAppear {
            maxAgeDays = MacClippyHistoryCapacity(maxAgeDays: maxAgeDays).maxAgeDays
            refreshPermissionStatus()
            launchAtLogin = SMAppService.mainApp.status == .enabled
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
        .onReceive(permissionRefreshTimer) { _ in
            refreshPermissionStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macClippyHotKeyUpdateFailed)) { notification in
            hotKeyError = notification.userInfo?[NSLocalizedDescriptionKey] as? String
            hotKeyDescriptor = (notification.userInfo?[MacClippyHotKeyNotificationUserInfo.descriptor] as? MacClippyGlobalHotKeyDescriptor)
                ?? MacClippyGlobalHotKeyDescriptor.load(from: .standard)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macClippyHotKeyUpdateSucceeded)) { _ in
            hotKeyError = nil
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

    private var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Settings")
                    .font(.system(size: 28, weight: .semibold))
            }
            Text("Control clipboard history, shortcuts, privacy, and permissions.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private var historySection: some View {
        MacClippySettingsGroup(
            title: "History",
            subtitle: "Pinned items are always kept. Older unpinned items are cleaned up automatically."
        ) {
            MacClippySettingsRow(
                title: "Keep clipboard history",
                detail: "How long new items stay available"
            ) {
                Picker("Keep clipboard history", selection: historyCapacityBinding) {
                    ForEach(MacClippyHistoryCapacity.allCases, id: \.self) { capacity in
                        Text(capacity.title).tag(capacity.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 310)
            }
            if selectedHistoryCapacity == .unlimited {
                Divider()
                Label("Unlimited history can use more disk space over time.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    private var presentationSection: some View {
        MacClippySettingsGroup(
            title: "App visibility",
            subtitle: "Choose where MacClippy stays available. The global shortcut always remains available."
        ) {
            MacClippySettingsRow(
                title: "Hide from menu bar",
                detail: hideFromMenuBar ? "Open the dock with the global shortcut" : "Keep the MacClippy icon in the menu bar"
            ) {
                Toggle("Hide from menu bar", isOn: $hideFromMenuBar)
                    .labelsHidden()
            }
            Divider()
            MacClippySettingsRow(
                title: "Hide Dock icon",
                detail: hideDockIcon ? "MacClippy runs as a menu bar app" : "Show MacClippy in the Dock"
            ) {
                Toggle("Hide Dock icon", isOn: $hideDockIcon)
                    .labelsHidden()
            }
            if hideFromMenuBar && hideDockIcon {
                Divider()
                Label(
                    "MacClippy will be accessible through the global shortcut only.",
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var shortcutSection: some View {
        MacClippySettingsGroup(
            title: "Shortcut",
            subtitle: "Use this shortcut from any app to open the clipboard dock."
        ) {
            MacClippySettingsRow(title: "Toggle dock", detail: nil) {
                MacClippyHotKeyRecorder(descriptor: $hotKeyDescriptor) { _ in
                    NotificationCenter.default.post(name: .macClippyHotKeyDescriptorChanged, object: nil)
                }
                .frame(width: 190, alignment: .trailing)
            }
            if let hotKeyError {
                Divider()
                Label(hotKeyError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    private var snippetsSection: some View {
        MacClippySettingsGroup(
            title: "Snippets",
            subtitle: "Choose whether ;triggers expand while you type."
        ) {
            MacClippySettingsRow(title: "Expansion", detail: nil) {
                Picker("Snippet expansion", selection: $snippetExpansionMode) {
                    Text("Automatically expand").tag(MacClippySnippetExpansionMode.autoExpand.rawValue)
                    Text("Confirm with Tab").tag(MacClippySnippetExpansionMode.confirmWithTab.rawValue)
                    Text("Off").tag(MacClippySnippetExpansionMode.disabled.rawValue)
                }
                .labelsHidden()
                .frame(width: 190)
            }
            if snippetExpansionMode != MacClippySnippetExpansionMode.disabled.rawValue,
               !accessibilityTrusted || !inputMonitoringTrusted {
                Label(
                    "Enable Accessibility and Input Monitoring below to expand snippets while typing.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private var permissionsSection: some View {
        MacClippySettingsGroup(
            title: "Permissions",
            subtitle: "Only needed for automatic paste, global shortcuts, and Snippet expansion."
        ) {
            permissionRow(
                title: "Accessibility",
                detail: "Automatic paste and Snippet expansion",
                enabled: accessibilityTrusted,
                action: openAccessibilitySettings
            )
            Divider()
            permissionRow(
                title: "Input Monitoring",
                detail: "Global shortcut and Snippet trigger monitoring",
                enabled: inputMonitoringTrusted,
                action: openInputMonitoringSettings
            )
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Permissions apply to this exact app copy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Bundle.main.bundleURL.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button("Refresh") { refreshPermissionStatus() }
                    if !accessibilityTrusted || !inputMonitoringTrusted {
                        Text("After changing access, quit and reopen MacClippy if macOS does not update the status.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var startupSection: some View {
        MacClippySettingsGroup(title: "Startup") {
            MacClippySettingsRow(
                title: "Launch at login",
                detail: "Keep MacClippy ready in the menu bar"
            ) {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .labelsHidden()
                    .onChange(of: launchAtLogin) { _, enabled in updateLaunchAtLogin(enabled) }
            }
            if let launchAtLoginError {
                Divider()
                Label(launchAtLoginError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    private var privacySection: some View {
        MacClippySettingsGroup(
            title: "Privacy",
            subtitle: "Clipboard data stays on this Mac unless you explicitly export diagnostics."
        ) {
            MacClippySettingsRow(
                title: "Pause capture",
                detail: privacyPause ? "New clipboard changes are not being saved" : "New clipboard changes are being saved"
            ) {
                Toggle("Pause capture", isOn: $privacyPause)
                    .labelsHidden()
            }
            Divider()
            MacClippySettingsRow(
                title: "Privacy & data notice",
                detail: "Review what MacClippy stores and how permissions are used"
            ) {
                Button("View notice…") { isPrivacyNoticePresented = true }
            }
            Divider()
            DisclosureGroup(isExpanded: $isCaptureRulesExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Ignore concealed pasteboard content", isOn: $excludeConcealed)
                    Toggle("Ignore transient pasteboard content", isOn: $excludeTransient)
                    Toggle("Capture All", isOn: $captureAll)
                    if captureAll {
                        Text("Capture All includes concealed and transient content. Built-in password-manager exclusions still apply.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Excluded app bundle IDs")
                        TextField("com.example.app, com.example.other", text: $excludedApps)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Excluded text patterns")
                        Text("One regular expression per line")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $excludedTextPatterns)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 76)
                            .scrollContentBackground(.hidden)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.top, 10)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Advanced capture rules")
                    Text("Exclude apps and content patterns from new captures")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var advancedSection: some View {
        MacClippySettingsGroup(
            title: "Advanced",
            subtitle: storageHealthSummary
        ) {
            DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    diagnosticsContent
                    Divider()
                    MacClippySettingsRow(
                        title: "Delete unpinned history",
                        detail: "Pinned items stay. Use this only for a manual cleanup."
                    ) {
                        Button("Delete…", role: .destructive) {
                            isDeleteHistoryConfirmationPresented = true
                        }
                        .disabled(isDeletingHistory)
                    }
                    if isDeletingHistory {
                        ProgressView("Deleting history…")
                            .controlSize(.small)
                            .padding(.horizontal, 16)
                    }
                    if let historyDeletionMessage {
                        Text(historyDeletionMessage)
                            .font(.footnote)
                            .foregroundStyle(historyDeletionMessageIsError ? .red : .secondary)
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 10)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(.secondary)
                    Text("Maintenance and data controls")
                    Spacer()
                    Text(storageHealthSummary)
                        .font(.caption)
                        .foregroundStyle(storageHealthHasIssue ? .orange : .secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        MacClippySettingsRow(title: title, detail: detail) {
            HStack(spacing: 10) {
                if enabled {
                    Label("Enabled", systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Needs access", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Button(enabled ? "Open Settings" : "Grant Access", action: action)
            }
        }
    }

    private var diagnosticsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if storageHealth.isEmpty {
                Text("Storage status is unavailable until MacClippy finishes starting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(storageHealthStatusText)
                    .font(.callout)
                    .foregroundStyle(storageHealthHasIssue ? .orange : .secondary)
            }
            if storageHealthHasIssue {
                Text("Repair the search index first. Database recovery requires a validated backup.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button("Refresh") { refreshStorageHealth() }
                Button("Repair Search Index") { repairSearchIndex() }
                    .disabled(isRepairingSearchIndex)
                Button("Export Diagnostics…") { exportDiagnostics() }
            }
            if isRepairingSearchIndex {
                ProgressView("Repairing search index…")
                    .controlSize(.small)
            }
            if let diagnosticsMessage {
                Text(diagnosticsMessage)
                    .font(.footnote)
                    .foregroundStyle(diagnosticsMessageIsError ? .red : .secondary)
            }
            Text("Diagnostics contain health counters and redacted events only; clipboard content is not included.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    private var selectedHistoryCapacity: MacClippyHistoryCapacity {
        MacClippyHistoryCapacity(maxAgeDays: maxAgeDays)
    }

    private var historyCapacityBinding: Binding<Int> {
        Binding(
            get: { selectedHistoryCapacity.rawValue },
            set: { maxAgeDays = MacClippyHistoryCapacity(rawValue: $0)?.maxAgeDays ?? MacClippyRetentionPreferences.defaultMaxAgeDays }
        )
    }

    private var storageHealthHasIssue: Bool {
        storageHealth.values.contains { $0.status != .healthy }
    }

    private var storageHealthStatusText: String {
        storageHealth.keys.sorted().compactMap { name in
            guard let report = storageHealth[name] else { return nil }
            return "\(name.capitalized): \(report.status.rawValue.capitalized)"
        }
        .joined(separator: "  ·  ")
    }

    private var storageHealthSummary: String {
        if storageHealth.isEmpty { return "Checking storage…" }
        return storageHealthHasIssue ? "Needs attention" : "Storage healthy"
    }

    private func refreshStorageHealth() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.refreshStorageHealth { health in
            storageHealth = health
        }
    }

    private func repairSearchIndex() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        diagnosticsMessage = nil
        diagnosticsMessageIsError = false
        isRepairingSearchIndex = true
        delegate.repairSearchIndex { result in
            isRepairingSearchIndex = false
            switch result {
            case let .success(report):
                if report.failedDocuments == 0 {
                    diagnosticsMessage = "Search index repaired (\(report.documentsWritten) documents)."
                } else {
                    diagnosticsMessage = "Search index repair completed with \(report.failedDocuments) unreadable record(s). Export diagnostics and review storage health."
                    diagnosticsMessageIsError = true
                }
                refreshStorageHealth()
            case .failure:
                diagnosticsMessage = "Search index repair failed. Export diagnostics and try again."
                diagnosticsMessageIsError = true
            }
        }
    }

    private func exportDiagnostics() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "MacClippy-Diagnostics.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try delegate.exportDiagnostics(to: url)
                diagnosticsMessage = "Diagnostics exported successfully."
                diagnosticsMessageIsError = false
            } catch {
                MacClippyLog.record(
                    category: .ui,
                    code: .backupFailed,
                    operation: "diagnostics_export",
                    recoveryAction: "choose_another_destination",
                    impact: "diagnostics_not_exported"
                )
                diagnosticsMessage = "Diagnostics export failed. Choose another destination and try again."
                diagnosticsMessageIsError = true
            }
        }
    }

    private func openAccessibilitySettings() {
        if !accessibilityTrusted {
            let options = [
                kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        refreshPermissionStatus()
    }

    private func openInputMonitoringSettings() {
        // Ask macOS to register this app for Input Monitoring before opening
        // the pane. Without this request, MacClippy may be missing from the
        // list entirely and its global Snippet event tap can never start.
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
        refreshPermissionStatus()
    }

    private func refreshPermissionStatus() {
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

    private func notifyPresentationPreferencesChanged() {
        NotificationCenter.default.post(name: .macClippyPresentationPreferencesChanged, object: nil)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            // Keep the toggle aligned with the service manager when register
            // or unregister is rejected (for example, pending approval).
            launchAtLogin = SMAppService.mainApp.status == .enabled
            MacClippyLog.record(
                category: .lifecycle,
                code: .launchAtLoginUpdateFailed,
                operation: "launch_at_login_settings_update",
                recoveryAction: "check_system_settings",
                impact: "launch_at_login_state_unchanged"
            )
            launchAtLoginError = "Could not update Launch at Login. Check System Settings and try again."
        }
    }

    private func deleteUnpinnedHistory() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        historyDeletionMessage = nil
        historyDeletionMessageIsError = false
        isDeletingHistory = true
        delegate.deleteUnpinnedHistory { result in
            isDeletingHistory = false
            switch result {
            case let .success(batch):
                let failures = batch.missingIDs.count + batch.failedIDs.count
                if failures == 0 {
                    historyDeletionMessage = "Deleted \(batch.deletedIDs.count) unpinned item(s)."
                } else {
                    historyDeletionMessage = "Deleted \(batch.deletedIDs.count) item(s); \(failures) could not be removed. Export diagnostics and try again."
                    historyDeletionMessageIsError = true
                }
            case .failure:
                historyDeletionMessage = "History deletion failed. Export diagnostics and try again."
                historyDeletionMessageIsError = true
            }
        }
    }
}

private struct MacClippySettingsGroup<Content: View>: View {
    let title: String
    let subtitle: String?
    private let content: () -> Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 4)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0, content: content)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
    }
}

private struct MacClippySettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    private let control: () -> Control

    init(title: String, detail: String?, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }
}

@MainActor
final class MacClippySettingsWindowCoordinator: NSObject, NSWindowDelegate {
    static let shared = MacClippySettingsWindowCoordinator()

    private weak var window: NSWindow?
    private var fallbackWindow: NSWindow?
    private var fallbackHostingView: NSHostingView<MacClippySettingsView>?

    func register(_ window: NSWindow) {
        self.window = window
    }

    func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            window.makeKey()
            return
        }
        if let fallbackWindow {
            fallbackWindow.makeKeyAndOrderFront(nil)
            fallbackWindow.orderFrontRegardless()
            fallbackWindow.makeKey()
            return
        }
        presentFallbackWindow()
    }

    private func presentFallbackWindow() {
        let hostingView = NSHostingView(rootView: MacClippySettingsView())
        let fallbackWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        fallbackWindow.title = "MacClippy Settings"
        fallbackWindow.contentView = hostingView
        fallbackWindow.isReleasedWhenClosed = false
        fallbackWindow.delegate = self
        fallbackWindow.minSize = NSSize(width: 560, height: 520)
        fallbackWindow.level = .normal
        fallbackWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        self.fallbackHostingView = hostingView
        self.fallbackWindow = fallbackWindow
        fallbackWindow.center()
        fallbackWindow.makeKeyAndOrderFront(nil)
        fallbackWindow.orderFrontRegardless()
        fallbackWindow.makeKey()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closedWindow = notification.object as? NSWindow,
              closedWindow === fallbackWindow else { return }
        window = nil
        fallbackHostingView = nil
        fallbackWindow = nil
    }
}

/// Re-applies regular-window behavior whenever SwiftUI creates or re-hydrates
/// the native Settings scene window. It deliberately does not join Spaces or
/// overlay another app's full-screen window.
private final class SettingsConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowConfiguration()
    }

    func applyWindowConfiguration() {
        guard let window else { return }
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.title = "MacClippy Settings"
        window.styleMask.insert([.titled, .closable, .resizable])
        window.collectionBehavior.remove([.fullScreenAuxiliary, .canJoinAllSpaces, .stationary, .ignoresCycle])
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenNone])
        MacClippySettingsWindowCoordinator.shared.register(window)
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsConfigurationView { SettingsConfigurationView() }

    func updateNSView(_ nsView: SettingsConfigurationView, context: Context) {
        nsView.applyWindowConfiguration()
    }
}
