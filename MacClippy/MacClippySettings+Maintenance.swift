import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

import MacClippyCore
import MacClippyPlatform


import ServiceManagement

extension MacClippySettingsView {
    #if DEBUG
    func insertRemoteClipboardSample() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        diagnosticsMessage = nil
        diagnosticsMessageIsError = false
        do {
            try delegate.insertRemoteClipboardSample()
            diagnosticsMessage = "Inserted a remote clipboard sample. Open the dock to see the icon."
        } catch {
            diagnosticsMessage = "Could not insert the remote clipboard sample."
            diagnosticsMessageIsError = true
        }
    }
    #endif

    func refreshStorageHealth() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.refreshStorageHealth { health in
            storageHealth = health
        }
    }

    func refreshStorageUsage() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.refreshStorageUsage { usage in
            storageUsage = usage
        }
    }

    func compressOldImages() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        imageCompressMessage = nil
        imageCompressMessageIsError = false
        isCompressingImages = true
        delegate.compressOldImages { result in
            isCompressingImages = false
            switch result {
            case let .success(report):
                imageCompressMessage = MacClippyStorageDashboardPolicy.compressMessage(
                    compressedCount: report.compressedCount,
                    bytesSaved: report.bytesSaved
                )
                refreshStorageUsage()
            case .failure:
                imageCompressMessage = "Could not compress old images. Export diagnostics and try again."
                imageCompressMessageIsError = true
            }
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

    var isBackupBusy: Bool {
        isRepairingSearchIndex || isExportingDiagnostics || isCreatingBackup || isRestoringBackup || isCompressingImages
    }

    func chooseExcludedApp() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Exclude"
        panel.message = "Choose an app whose copies should not be saved."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
            excludedApps = MacClippyExclusionAppPickerPolicy.add(bundleID, to: excludedApps)
        }
    }

    func createBackup() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = MacClippyBackupSettingsPolicy.suggestedFolderName()
        panel.prompt = "Create Backup"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            isCreatingBackup = true
            diagnosticsMessage = nil
            diagnosticsMessageIsError = false
            delegate.createBackup(at: url) { result in
                isCreatingBackup = false
                switch result {
                case let .success(manifest):
                    diagnosticsMessage = MacClippyBackupSettingsPolicy.createSuccessMessage(
                        databaseCount: manifest.databaseNames.count
                    )
                    diagnosticsMessageIsError = false
                case let .failure(error):
                    diagnosticsMessage = backupFailureMessage(error, fallback: "Backup failed. Choose another destination and try again.")
                    diagnosticsMessageIsError = true
                }
            }
        }
    }

    func chooseBackupToRestore() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Restore"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard MacClippyBackupSettingsPolicy.containsManifest(at: url) else {
                diagnosticsMessage = MacClippyBackupSettingsPolicy.message(for: .invalidManifest)
                diagnosticsMessageIsError = true
                return
            }
            isRestoringBackup = true
            diagnosticsMessage = nil
            diagnosticsMessageIsError = false
            delegate.restoreBackup(from: url) { result in
                isRestoringBackup = false
                switch result {
                case .success:
                    diagnosticsMessage = MacClippyBackupSettingsPolicy.restoreSuccessMessage()
                    diagnosticsMessageIsError = false
                    refreshStorageHealth()
                case let .failure(error):
                    diagnosticsMessage = backupFailureMessage(error, fallback: "Restore failed. Export diagnostics and try again.")
                    diagnosticsMessageIsError = true
                }
            }
        }
    }

    func backupFailureMessage(_ error: Error, fallback: String) -> String {
        if let backupError = error as? MacClippyBackupError {
            return MacClippyBackupSettingsPolicy.message(for: backupError)
        }
        return fallback
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
            try MacClippyLaunchAtLoginRegistration.setEnabled(enabled)
            launchAtLoginError = nil
        } catch MacClippyLaunchAtLoginRegistration.Error.debugBuildRefused {
            launchAtLogin = false
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
        Group {
            MacClippySettingsGroup(
                title: "Storage",
                subtitle: storageHealthSummary
            ) {
                MacClippySettingsRow(
                    title: "Health",
                    detail: storageHealthStatusDetail
                ) {
                    Button("Refresh") { refreshStorageHealth() }
                }
                if storageHealthHasIssue {
                    MacClippySettingsNote(
                        text: "Repair the search index first. Database recovery requires a validated backup.",
                        tone: .warning
                    )
                }
                MacClippySettingsRow(
                    title: "Repair search index",
                    detail: "Rebuild search so history queries match current items."
                ) {
                    Button("Repair") { repairSearchIndex() }
                        .disabled(isBackupBusy)
                }
                if isRepairingSearchIndex {
                    ProgressView("Repairing search index…")
                        .controlSize(.small)
                }
                if let diagnosticsMessage {
                    MacClippySettingsNote(
                        text: diagnosticsMessage,
                        tone: diagnosticsMessageIsError ? .danger : .info
                    )
                }
            }
            MacClippySettingsGroup(
                title: "Backup & diagnostics",
                subtitle: "Diagnostics contain health counters and redacted events only. A backup includes local history, pinboards, snippets, and images."
            ) {
                MacClippySettingsRow(
                    title: "Export diagnostics",
                    detail: "Save a support file with health counters and redacted events."
                ) {
                    Button("Export…") { exportDiagnostics() }
                        .disabled(isBackupBusy)
                }
                if isExportingDiagnostics {
                    ProgressView("Exporting diagnostics…")
                        .controlSize(.small)
                }
                MacClippySettingsRow(
                    title: "Create backup",
                    detail: "Save a local archive of history, pinboards, snippets, and images."
                ) {
                    Button("Create…") { createBackup() }
                        .disabled(isBackupBusy)
                }
                if isCreatingBackup {
                    ProgressView("Creating backup…")
                        .controlSize(.small)
                }
                MacClippySettingsRow(
                    title: "Restore backup",
                    detail: "Replace history, pinboards, and snippets on this Mac with a backup."
                ) {
                    Button("Restore…") { isRestoreBackupConfirmationPresented = true }
                        .disabled(isBackupBusy)
                }
                if isRestoringBackup {
                    ProgressView("Restoring backup…")
                        .controlSize(.small)
                }
                if let diagnosticsMessage {
                    MacClippySettingsNote(
                        text: diagnosticsMessage,
                        tone: diagnosticsMessageIsError ? .danger : .info
                    )
                }
            }
            #if DEBUG
            MacClippySettingsGroup(
                title: "Preview samples",
                subtitle: "Debug-only. Adds a history card stamped with com.apple.is-remote-clipboard."
            ) {
                MacClippySettingsRow(
                    title: "Remote clipboard sample",
                    detail: "Insert a card so the bottom-left remote icon is visible in the dock."
                ) {
                    Button("Insert") { insertRemoteClipboardSample() }
                }
            }
            #endif
            MacClippySettingsGroup(
                title: "History",
                subtitle: "Pinned items stay. Use this only for a manual cleanup."
            ) {
                MacClippySettingsRow(
                    title: "Delete unpinned history",
                    detail: "Remove unpinned clipboard items, search entries, and associated blobs."
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
                    MacClippySettingsNote(
                        text: historyDeletionMessage,
                        tone: historyDeletionMessageIsError ? .danger : .info
                    )
                }
            }
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
