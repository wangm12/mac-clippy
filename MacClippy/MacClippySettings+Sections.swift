import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

import MacClippyCore
import MacClippyPlatform


extension MacClippySettingsView {
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
                .frame(width: MacClippySettingsMetrics.historyPickerWidth)
            }
            .macClippySettingsNote(
                selectedHistoryCapacity == .unlimited
                    ? "Unlimited history can use more disk space over time."
                    : nil,
                tone: .warning
            )
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
            MacClippySettingsRow(
                title: "Hide Dock icon",
                detail: hideDockIcon
                    ? (hideFromMenuBar ? "Open MacClippy with the global shortcut" : "MacClippy runs as a menu bar app")
                    : "Show MacClippy in the Dock"
            ) {
                Toggle("Hide Dock icon", isOn: $hideDockIcon)
                    .labelsHidden()
            }
            .macClippySettingsNote(
                hideFromMenuBar && hideDockIcon
                    ? "MacClippy will be accessible through the global shortcut only."
                    : nil,
                tone: .info
            )
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
            .macClippySettingsNote(hotKeyError, tone: .danger)
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
            MacClippySettingsRow(
                title: "Privacy & data notice",
                detail: "Review what MacClippy stores and how permissions are used"
            ) {
                Button("View notice…") { isPrivacyNoticePresented = true }
            }
            MacClippySettingsDisclosure(
                title: "Advanced capture rules",
                detail: "Exclude apps and content patterns from new captures",
                isExpanded: $isCaptureRulesExpanded,
                reduceMotion: reduceMotion
            )
            if isCaptureRulesExpanded {
                MacClippySettingsRow(
                    title: "Ignore concealed pasteboard content",
                    detail: nil
                ) {
                    Toggle("Ignore concealed pasteboard content", isOn: $excludeConcealed)
                        .labelsHidden()
                }
                MacClippySettingsRow(
                    title: "Ignore transient pasteboard content",
                    detail: nil
                ) {
                    Toggle("Ignore transient pasteboard content", isOn: $excludeTransient)
                        .labelsHidden()
                }
                MacClippySettingsRow(
                    title: "Capture All",
                    detail: nil
                ) {
                    Toggle("Capture All", isOn: $captureAll)
                        .labelsHidden()
                }
                .macClippySettingsNote(
                    captureAll
                        ? "Capture All includes concealed and transient content. Built-in password-manager exclusions still apply."
                        : nil,
                    tone: .warning
                )
                MacClippySettingsField(title: "Excluded app bundle IDs") {
                    TextField("com.example.app, com.example.other", text: $excludedApps)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Excluded app bundle IDs")
                }
                MacClippySettingsField(
                    title: "Excluded text patterns",
                    detail: "One regular expression per line"
                ) {
                    TextEditor(text: $excludedTextPatterns)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 76)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Excluded text patterns")
                        .accessibilityHint("Enter one regular expression per line")
                }
            }
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

    var selectedHistoryCapacity: MacClippyHistoryCapacity {
        MacClippyHistoryCapacity(maxAgeDays: maxAgeDays)
    }

    var historyCapacityBinding: Binding<Int> {
        Binding(
            get: { selectedHistoryCapacity.rawValue },
            set: { maxAgeDays = MacClippyHistoryCapacity(rawValue: $0)?.maxAgeDays ?? MacClippyRetentionPreferences.defaultMaxAgeDays }
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

@resultBuilder
enum MacClippySettingsListBuilder {
    static func buildExpression<V: View>(_ view: V) -> [AnyView] {
        [AnyView(view)]
    }

    static func buildBlock(_ parts: [AnyView]...) -> [AnyView] {
        parts.flatMap { $0 }
    }

    static func buildOptional(_ part: [AnyView]?) -> [AnyView] {
        part ?? []
    }

    static func buildEither(first part: [AnyView]) -> [AnyView] {
        part
    }

    static func buildEither(second part: [AnyView]) -> [AnyView] {
        part
    }

    static func buildArray(_ parts: [[AnyView]]) -> [AnyView] {
        parts.flatMap { $0 }
    }
}

struct MacClippySettingsHairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

struct MacClippySettingsList: View {
    let items: [AnyView]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    MacClippySettingsHairline()
                }
                item
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, MacClippySettingsMetrics.rowVerticalPadding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MacClippySettingsGroup: View {
    let title: String
    let subtitle: String?
    private let items: [AnyView]

    init(
        title: String,
        subtitle: String? = nil,
        @MacClippySettingsListBuilder content: () -> [AnyView]
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = content()
    }

    var body: some View {
        Section {
            MacClippySettingsList(items: items)
                .listRowSeparator(.hidden)
        } header: {
            Text(title)
        } footer: {
            if let subtitle {
                Text(subtitle)
            }
        }
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
        }
    }
}

struct MacClippySettingsDisclosure: View {
    let title: String
    let detail: String?
    @Binding var isExpanded: Bool
    var reduceMotion: Bool = false

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
    var detail: String? = nil
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
