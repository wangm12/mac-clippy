import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

import MacClippyCore
import MacClippyPlatform


import ServiceManagement

extension MacClippySettingsView {
    func refreshStorageHealth() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.refreshStorageHealth { health in
            storageHealth = health
        }
    }

    func repairSearchIndex() {
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

    func exportDiagnostics() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "MacClippy-Diagnostics.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            isExportingDiagnostics = true
            delegate.exportDiagnostics(to: url) { result in
                isExportingDiagnostics = false
                switch result {
                case .success:
                    diagnosticsMessage = "Diagnostics exported successfully."
                    diagnosticsMessageIsError = false
                case .failure:
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
    }

    func notifyPresentationPreferencesChanged() {
        NotificationCenter.default.post(name: .macClippyPresentationPreferencesChanged, object: nil)
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
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

    func deleteUnpinnedHistory() {
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

    var advancedSection: some View {
        MacClippySettingsGroup(
            title: "Advanced",
            subtitle: storageHealthSummary
        ) {
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
            }
            if let historyDeletionMessage {
                Text(historyDeletionMessage)
                    .font(.footnote)
                    .foregroundStyle(historyDeletionMessageIsError ? .red : .secondary)
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
