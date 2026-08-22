import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

import MacClippyCore
import MacClippyPlatform


extension MacClippySettingsView {
    var settingsHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Settings")
                    .font(.title2.weight(.semibold))
            }
            Text("Control clipboard history, shortcuts, privacy, and permissions.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
        .padding(.bottom, 4)
    }

    var historySection: some View {
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

    var presentationSection: some View {
        MacClippySettingsGroup(
            title: "App visibility",
            subtitle: "Choose where MacClippy stays available. The global shortcut always remains available."
        ) {
            MacClippySettingsRow(
                title: "Hide menu bar icon",
                detail: hideFromMenuBar ? "Open the dock with the global shortcut" : "Keep the MacClippy icon in the menu bar"
            ) {
                Toggle("Hide menu bar icon", isOn: $hideFromMenuBar)
                    .labelsHidden()
            }
            Divider()
            MacClippySettingsRow(
                title: "Hide Dock icon",
                detail: hideDockIcon
                    ? (hideFromMenuBar ? "Open MacClippy with the global shortcut" : "MacClippy runs as a menu bar app")
                    : "Show MacClippy in the Dock"
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

    var shortcutSection: some View {
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

    var snippetsSection: some View {
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

    var permissionsSection: some View {
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
            if let permissionSettingsError {
                Divider()
                Label(permissionSettingsError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Permissions apply to this exact app copy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Bundle.main.bundleURL.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !MacClippyPermissionTrustPolicy.permissionsCanPersist(MacClippyCodeSignature.kind()) {
                    Text(MacClippyPermissionTrustPolicy.unsignedCopyExplanation())
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    var startupSection: some View {
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

    var privacySection: some View {
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
                            .accessibilityLabel("Excluded text patterns")
                            .accessibilityHint("Enter one regular expression per line")
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

    var advancedSection: some View {
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

    func permissionRow(
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

    var diagnosticsContent: some View {
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
                    .disabled(isRepairingSearchIndex || isExportingDiagnostics)
                Button("Export Diagnostics…") { exportDiagnostics() }
                    .disabled(isRepairingSearchIndex || isExportingDiagnostics)
            }
            if isRepairingSearchIndex {
                ProgressView("Repairing search index…")
                    .controlSize(.small)
            }
            if isExportingDiagnostics {
                ProgressView("Exporting diagnostics…")
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

    var selectedHistoryCapacity: MacClippyHistoryCapacity {
        MacClippyHistoryCapacity(maxAgeDays: maxAgeDays)
    }

    var historyCapacityBinding: Binding<Int> {
        Binding(
            get: { selectedHistoryCapacity.rawValue },
            set: { maxAgeDays = MacClippyHistoryCapacity(rawValue: $0)?.maxAgeDays ?? MacClippyRetentionPreferences.defaultMaxAgeDays }
        )
    }

    var storageHealthHasIssue: Bool {
        storageHealth.values.contains { $0.status != .healthy }
    }

    var storageHealthStatusText: String {
        storageHealth.keys.sorted().compactMap { name in
            guard let report = storageHealth[name] else { return nil }
            return "\(name.capitalized): \(report.status.rawValue.capitalized)"
        }
        .joined(separator: "  ·  ")
    }

    var storageHealthSummary: String {
        if storageHealth.isEmpty { return "Checking storage…" }
        return storageHealthHasIssue ? "Needs attention" : "Storage healthy"
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
                .accessibilityAddTraits(.isHeader)
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
