import AppKit
import Foundation
import SwiftUI

import MacClippyCore
import MacClippyPlatform

extension MacClippySettingsView {
    var pasteSection: some View {
        MacClippySettingsGroup(
            title: "Paste",
            subtitle: "Return pastes formatted content. Shift-Return pastes plain text."
        ) {
            MacClippySettingsRow(
                title: "Always paste as plain text",
                detail: alwaysPastePlainText
                    ? "Return pastes unformatted text. Shift-Return restores formatting."
                    : "Return keeps the original formatting. Shift-Return pastes plain text."
            ) {
                Toggle("Always paste as plain text", isOn: $alwaysPastePlainText)
                    .labelsHidden()
            }
        }
    }

    var snippetsSection: some View {
        MacClippySettingsGroup(
            title: "Snippets",
            subtitle: MacClippySnippetPreferences.expansionInstructions(for: snippetExpansionMode)
        ) {
            MacClippySettingsRow(title: "Expansion", detail: nil) {
                Picker("Snippet expansion", selection: $snippetExpansionMode) {
                    Text("Expand with Space").tag(MacClippySnippetExpansionMode.autoExpand.rawValue)
                    Text("Confirm with Tab").tag(MacClippySnippetExpansionMode.confirmWithTab.rawValue)
                    Text("Off").tag(MacClippySnippetExpansionMode.disabled.rawValue)
                }
                .labelsHidden()
                .frame(width: 190)
            }
            .macClippySettingsNote(
                snippetExpansionMode != MacClippySnippetExpansionMode.disabled.rawValue
                    && (!accessibilityTrusted || !inputMonitoringTrusted)
                    ? "Enable Accessibility and Input Monitoring to expand snippets while typing."
                    : nil,
                tone: .warning
            )
        }
    }

    var permissionsSection: some View {
        Group {
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
                permissionRow(
                    title: "Input Monitoring",
                    detail: "Global shortcut and Snippet trigger monitoring",
                    enabled: inputMonitoringTrusted,
                    action: openInputMonitoringSettings
                )
                .macClippySettingsNote(permissionSettingsError, tone: .danger)
            }

            MacClippySettingsGroup(
                title: "This copy",
                subtitle: thisCopySubtitle
            ) {
                VStack(alignment: .leading, spacing: MacClippySettingsMetrics.noteSpacing) {
                    Text(Bundle.main.bundleURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        Button("Refresh") { refreshPermissionStatus() }
                        if !accessibilityTrusted || !inputMonitoringTrusted {
                            Text("Quit and reopen MacClippy if macOS does not update the status.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
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
            .macClippySettingsNote(launchAtLoginError, tone: .danger)
            .macClippySettingsNote(
                MacClippyLaunchAtLoginRegistration.warningMessage(),
                tone: .warning
            )
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

    var thisCopySubtitle: String {
        if !MacClippyPermissionTrustPolicy.permissionsCanPersist(MacClippyCodeSignature.kind()) {
            return MacClippyPermissionTrustPolicy.unsignedCopyExplanation()
        }
        return "Permissions apply to this exact app copy."
    }

    var userExcludedAppRows: [MacClippyExcludedAppRow] {
        MacClippyExclusionAppPickerPolicy.rows(
            stored: excludedApps,
            displayNames: excludedAppDisplayNames
        ).filter(\.canRemove)
    }

    var excludedAppDisplayNames: [String: String] {
        Dictionary(
            uniqueKeysWithValues: MacClippyExclusionAppPickerPolicy.userBundleIDs(from: excludedApps).map {
                ($0, excludedAppDisplayName($0))
            }
        )
    }

    func excludedAppDisplayName(_ bundleID: String) -> String {
        let localizedName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            FileManager.default.displayName(atPath: $0.path)
        }
        return MacClippyExclusionAppPickerPolicy.displayTitle(
            bundleID: bundleID,
            localizedName: localizedName
        )
    }
}

enum MacClippySettingsNoteTone {
    case info
    case warning
    case danger

    var icon: String {
        switch self {
        case .info: "info.circle"
        case .warning, .danger: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .info: .secondary
        case .warning: .orange
        case .danger: .red
        }
    }
}

struct MacClippySettingsNote: View {
    let text: String
    var tone: MacClippySettingsNoteTone = .info

    var body: some View {
        Label(text, systemImage: tone.icon)
            .font(.footnote)
            .foregroundStyle(tone.color)
            .fixedSize(horizontal: false, vertical: true)
            .labelStyle(.titleAndIcon)
    }
}

struct MacClippySettingsRow<Control: View>: View {
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
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .accessibilityLabel(title)
                .accessibilityHint(detail ?? "")
        }
    }
}

struct MacClippySettingsDisclosure: View {
    let title: String
    let detail: String?
    @Binding var isExpanded: Bool
    var reduceMotion = false

    var body: some View {
        Button {
            withAnimation(MacClippyMotion.animation(MacClippyMotion.contentAnimation, reduceMotion: reduceMotion)) {
                isExpanded.toggle()
            }
        } label: {
            MacClippySettingsRow(title: title, detail: detail) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(detail ?? "")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

struct MacClippySettingsField<Content: View>: View {
    let title: String
    let detail: String?
    private let content: () -> Content

    init(title: String, detail: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Color.primary.opacity(0.045),
                    in: RoundedRectangle(
                        cornerRadius: MacClippySettingsMetrics.fieldCornerRadius,
                        style: .continuous
                    )
                )
        }
    }
}

extension View {
    @ViewBuilder
    func macClippySettingsNote(_ text: String?, tone: MacClippySettingsNoteTone) -> some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: MacClippySettingsMetrics.noteSpacing) {
                self
                MacClippySettingsNote(text: text, tone: tone)
            }
        } else {
            self
        }
    }
}
