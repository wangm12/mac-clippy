import SwiftUI

struct MacClippyCloudLocalRestoreSheet: View {
    let items: [MacClippyCloudLocalBackupItem]
    let onSelect: (MacClippyCloudLocalBackupItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore from iCloud Drive")
                .font(.headline)
            if items.isEmpty {
                Text("No .macclippybackup archives found in the configured folder.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(items) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.body)
                                Text(subtitle(for: item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if item.isCloudPlaceholder {
                                Text("In iCloud")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 220)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func subtitle(for item: MacClippyCloudLocalBackupItem) -> String {
        let size = ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file)
        let date = item.modifiedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(date)  ·  \(size)"
    }
}

struct MacClippyGoogleDriveRestoreSheet: View {
    let files: [MacClippyGoogleDriveBackupFile]
    let onSelect: (MacClippyGoogleDriveBackupFile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore from Google Drive")
                .font(.headline)
            if files.isEmpty {
                Text("No backups found in Google Drive appDataFolder.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List(files) { file in
                    Button {
                        onSelect(file)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(.body)
                                Text(subtitle(for: file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 220)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func subtitle(for file: MacClippyGoogleDriveBackupFile) -> String {
        let size = ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file)
        let date = file.createdTime.formatted(date: .abbreviated, time: .shortened)
        return "\(date)  ·  \(size)"
    }
}

extension MacClippySettingsView {
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

    var storageHealthStatusDetail: String {
        if storageHealth.isEmpty {
            return "Unavailable until MacClippy finishes starting."
        }
        return storageHealthStatusText
    }

    var storageHealthSummary: String {
        if storageHealth.isEmpty { return "Checking storage…" }
        return storageHealthHasIssue ? "Needs attention" : "Storage healthy"
    }
}
