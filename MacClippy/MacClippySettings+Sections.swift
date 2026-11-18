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
            if let storageUsage {
                ForEach(
                    MacClippyStorageDashboardPolicy.rows(from: storageUsage),
                    id: \.kind
                ) { row in
                    MacClippySettingsRow(
                        title: row.title,
                        detail: "\(row.usedLabel) of \(row.capLabel)"
                    ) {
                        ProgressView(value: min(max(row.fraction, 0), 1))
                            .frame(width: 120)
                    }
                }
            }
            MacClippySettingsRow(
                title: "Compress old images",
                detail: "Downscale unpinned images older than 7 days. Pinned items stay full size."
            ) {
                Button("Compress") { compressOldImages() }
                    .disabled(isCompressingImages || isBackupBusy)
            }
            if isCompressingImages {
                ProgressView("Compressing old images…")
                    .controlSize(.small)
            }
            if let imageCompressMessage {
                MacClippySettingsNote(
                    text: imageCompressMessage,
                    tone: imageCompressMessageIsError ? .danger : .info
                )
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
            MacClippySettingsRow(
                title: "Quit Mac Clippy",
                detail: "Stop clipboard capture and close the app."
            ) {
                Button("Quit") { NSApp.terminate(nil) }
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
            .macClippySettingsNote(hotKeyError, tone: .danger)
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
                    .onChange(of: privacyPause) { _, enabled in
                        persistTimedPause(enabled: enabled)
                    }
            }
            MacClippySettingsRow(
                title: "Pause duration",
                detail: "Automatically resume capture after this interval"
            ) {
                Picker("Pause duration", selection: $pauseDurationSeconds) {
                    ForEach(MacClippyTimedPauseDuration.allCases, id: \.rawValue) { duration in
                        Text(duration.title).tag(duration.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: pauseDurationSeconds) { _, _ in
                    if privacyPause {
                        persistTimedPause(enabled: true)
                    }
                }
            }
            MacClippySettingsRow(
                title: "Ignore next copy",
                detail: "⇧⌥⌘C skips the next clipboard change without pausing capture"
            ) {
                Button("Skip next copy") {
                    NotificationCenter.default.post(name: .macClippyIgnoreNextCopyRequested, object: nil)
                }
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
                MacClippySettingsField(
                    title: "Excluded apps",
                    detail: "Choose apps to skip. Password managers stay excluded."
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(userExcludedAppRows) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title)
                                    Text(row.bundleID)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer(minLength: 8)
                                Button("Remove") {
                                    excludedApps = MacClippyExclusionAppPickerPolicy.remove(
                                        row.bundleID,
                                        from: excludedApps
                                    )
                                }
                                .accessibilityLabel("Remove \(row.title)")
                            }
                        }
                        if userExcludedAppRows.isEmpty {
                            Text("No extra apps excluded")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Button("Add App…") { chooseExcludedApp() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Excluded apps")
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

    var selectedHistoryCapacity: MacClippyHistoryCapacity {
        MacClippyHistoryCapacity(maxAgeDays: maxAgeDays)
    }

    var historyCapacityBinding: Binding<Int> {
        Binding(
            get: { selectedHistoryCapacity.rawValue },
            set: { newValue in
                let capacity = MacClippyHistoryCapacity(rawValue: newValue)
                maxAgeDays = capacity?.maxAgeDays ?? MacClippyRetentionPreferences.defaultMaxAgeDays
            }
        )
    }

    func persistTimedPause(enabled: Bool) {
        let duration = MacClippyTimedPauseDuration(rawValue: pauseDurationSeconds) ?? .fiveMinutes
        MacClippyRetentionPreferences.applyPause(
            enabled: enabled,
            duration: duration, defaults: defaults
        )
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
