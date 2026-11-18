import AppKit
import MacClippyCore
import SwiftUI

struct MacClippyCloudBackupSettingsGroup: View {
    @ObservedObject private var manager = MacClippyCloudBackupManager.shared
    @State private var isWorking = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var clientSecretDraft = ""
    @State private var isICloudRestorePickerPresented = false
    @State private var localICloudBackups: [MacClippyCloudLocalBackupItem] = []
    @State private var isGooglePickerPresented = false
    @State private var googleBackups: [MacClippyGoogleDriveBackupFile] = []

    var body: some View {
        Group {
            cloudEncryptionSection
            iCloudSection
            googleDriveSection
        }
        .onAppear { manager.refreshConnectionState() }
        .sheet(isPresented: $isICloudRestorePickerPresented) {
            MacClippyCloudLocalRestoreSheet(items: localICloudBackups) { item in
                isICloudRestorePickerPresented = false
                restoreFromICloud(item)
            }
        }
        .sheet(isPresented: $isGooglePickerPresented) {
            MacClippyGoogleDriveRestoreSheet(files: googleBackups) { file in
                isGooglePickerPresented = false
                restoreFromGoogleDrive(file)
            }
        }
    }

    private var cloudEncryptionSection: some View {
        MacClippySettingsGroup(
            title: "Cloud & Cross-Mac Backups",
            subtitle: "Streaming .macclippybackup archives protected by your passphrase "
                + "for restoring onto another Mac or after Keychain loss."
        ) {
            MacClippySettingsRow(
                title: "Cloud backup passphrase",
                detail: manager.hasSavedPassphrase
                    ? "Stored in Keychain for iCloud Drive and Google Drive backups"
                    : "Set a passphrase to enable automatic or 1-click cloud backups"
            ) {
                HStack(spacing: 8) {
                    Button(manager.hasSavedPassphrase ? "Change…" : "Set…") { configurePassphrase() }
                        .disabled(isWorking)
                    if manager.hasSavedPassphrase {
                        Button("Clear") { clearSavedPassphrase() }.disabled(isWorking)
                    }
                }
            }
            MacClippySettingsRow(title: "Automatic backup schedule", detail: lastBackupSummary) {
                Picker("Schedule", selection: scheduleBinding) {
                    ForEach(MacClippyCloudBackupSchedule.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            if isWorking {
                ProgressView("Running cloud backup task…").controlSize(.small)
            }
            if let statusMessage {
                MacClippySettingsNote(text: statusMessage, tone: statusIsError ? .danger : .info)
            }
        }
    }

    private var iCloudSection: some View {
        MacClippySettingsGroup(
            title: "iCloud Drive Backup",
            subtitle: "Folder: \(manager.resolvedICloudFolderURL.path)"
        ) {
            MacClippySettingsRow(
                title: "Sync backups to iCloud Drive",
                detail: "Writes encrypted .macclippybackup archives and keeps the latest 5"
            ) {
                Toggle("Sync backups to iCloud Drive", isOn: iCloudBinding)
                    .labelsHidden()
            }
            MacClippySettingsRow(
                title: "Backup folder",
                detail: "Default uses iCloud Drive; pick any synced folder to override"
            ) {
                HStack(spacing: 8) {
                    Button("Choose…") { chooseICloudFolder() }
                        .disabled(isWorking)
                    Button("Default") {
                        manager.clearCustomICloudFolder()
                        setStatus("Reset iCloud folder to default.", isError: false)
                    }
                    .disabled(isWorking)
                }
            }
            MacClippySettingsRow(
                title: "iCloud actions",
                detail: "Create or restore a passphrase-encrypted archive in iCloud Drive"
            ) {
                HStack(spacing: 8) {
                    Button("Back Up Now") { backUpToICloudNow() }
                        .disabled(isWorking)
                    Button("Restore…") { openICloudRestorePicker() }
                        .disabled(isWorking)
                }
            }
        }
    }

    private var googleDriveSection: some View {
        MacClippySettingsGroup(
            title: "Google Drive Direct Connect",
            subtitle: """
            Connects directly via OAuth 2.0 PKCE with hidden appDataFolder scope only. \
            Mac Clippy cannot see your other Google Drive files and makes no requests when disconnected.
            """
        ) {
            MacClippySettingsField(
                title: "Google OAuth Client ID",
                detail: "Desktop app OAuth Client ID from Google Cloud Console"
            ) {
                TextField("xxxxxxxx.apps.googleusercontent.com", text: clientIDBinding)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
            }
            MacClippySettingsField(
                title: "Client Secret (optional)",
                detail: "Sent only when required by your Desktop OAuth client"
            ) {
                SecureField("Optional client secret", text: $clientSecretDraft)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
            }
            MacClippySettingsRow(
                title: "Account status",
                detail: manager.driveClient.connectedAccountSummary ?? "Not connected"
            ) {
                if manager.isGoogleConnected {
                    Button("Disconnect", role: .destructive) { disconnectGoogleDrive() }
                        .disabled(isWorking)
                } else {
                    Button("Connect Google Drive…") { connectGoogleDrive() }
                        .disabled(isWorking)
                }
            }
            MacClippySettingsRow(
                title: "Google Drive actions",
                detail: "Uploads via resumable chunks to hidden appDataFolder (keeps latest 5)"
            ) {
                HStack(spacing: 8) {
                    Button("Back Up Now") { backUpToGoogleDriveNow() }
                        .disabled(isWorking || !manager.isGoogleConnected)
                    Button("Restore…") { openGoogleDrivePicker() }
                        .disabled(isWorking || !manager.isGoogleConnected)
                }
            }
        }
    }

    private var scheduleBinding: Binding<MacClippyCloudBackupSchedule> {
        Binding(get: { manager.schedule }, set: { manager.setSchedule($0) })
    }

    private var iCloudBinding: Binding<Bool> {
        Binding(get: { manager.iCloudEnabled }, set: { manager.setICloudEnabled($0) })
    }

    private var clientIDBinding: Binding<String> {
        Binding(get: { manager.googleClientID }, set: { manager.setGoogleClientID($0) })
    }

    private var lastBackupSummary: String {
        guard let date = manager.lastBackupDate else { return "No cloud backup recorded yet" }
        return "Last backup: \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

private extension MacClippyCloudBackupSettingsGroup {
    func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    func resolvedPassphraseForBackup() -> String? {
        if let saved = manager.keychain.loadPassphrase() {
            return saved
        }
        guard let entered = MacClippyBackupPassphrasePrompt.promptForCreation() else { return nil }
        try? manager.savePassphrase(entered)
        return entered
    }

    func configurePassphrase() {
        guard let entered = MacClippyBackupPassphrasePrompt.promptForCreation() else { return }
        do {
            try manager.savePassphrase(entered)
            setStatus("Cloud backup passphrase saved to Keychain.", isError: false)
        } catch {
            setStatus("Could not save passphrase in Keychain.", isError: true)
        }
    }

    func clearSavedPassphrase() {
        do {
            try manager.savePassphrase("")
            setStatus("Cleared saved cloud backup passphrase.", isError: false)
        } catch {
            setStatus("Could not clear passphrase from Keychain.", isError: true)
        }
    }

    func chooseICloudFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try manager.saveCustomICloudFolder(url)
                setStatus("iCloud backup folder set to \(url.lastPathComponent).", isError: false)
            } catch {
                setStatus("Could not save selected folder.", isError: true)
            }
        }
    }

    func backUpToICloudNow() {
        guard let delegate = NSApp.delegate as? AppDelegate,
              let passphrase = resolvedPassphraseForBackup() else { return }
        isWorking = true
        setStatus("Creating encrypted archive…", isError: false)
        let tempArchiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(MacClippyCloudBackupManager.timestampedArchiveFileName())
        delegate.createArchiveBackup(at: tempArchiveURL, passphrase: passphrase, overwrite: true) { result in
            defer { try? FileManager.default.removeItem(at: tempArchiveURL) }
            switch result {
            case .success:
                do {
                    let savedURL = try manager.publishArchiveToFolder(
                        sourceArchiveURL: tempArchiveURL,
                        fileName: tempArchiveURL.lastPathComponent,
                        folderURL: manager.resolvedICloudFolderURL
                    )
                    manager.markBackupSucceeded()
                    setStatus("Saved iCloud backup \(savedURL.lastPathComponent).", isError: false)
                } catch {
                    setStatus("Failed moving archive to iCloud folder: \(error.localizedDescription)", isError: true)
                }
            case let .failure(error):
                setStatus(MacClippyBackupPassphrasePrompt.userMessage(for: error), isError: true)
            }
            isWorking = false
        }
    }

    func openICloudRestorePicker() {
        localICloudBackups = manager.listLocalArchives(in: manager.resolvedICloudFolderURL)
        isICloudRestorePickerPresented = true
    }

    func restoreFromICloud(_ item: MacClippyCloudLocalBackupItem) {
        guard let delegate = NSApp.delegate as? AppDelegate,
              let passphrase = MacClippyBackupPassphrasePrompt.promptForUnlock() else { return }
        isWorking = true
        setStatus("Preparing \(item.name)…", isError: false)
        Task {
            do {
                let hydratedURL = try await manager.hydrateCloudFileIfNeeded(at: item.url)
                delegate.restoreArchiveBackup(from: hydratedURL, passphrase: passphrase) { result in
                    isWorking = false
                    switch result {
                    case .success:
                        setStatus(MacClippyBackupSettingsPolicy.restoreSuccessMessage(), isError: false)
                    case let .failure(error):
                        setStatus(MacClippyBackupPassphrasePrompt.userMessage(for: error), isError: true)
                    }
                }
            } catch {
                isWorking = false
                setStatus("Could not download iCloud backup: \(error.localizedDescription)", isError: true)
            }
        }
    }

    func connectGoogleDrive() {
        isWorking = true
        setStatus("Waiting for browser authorization…", isError: false)
        let clientID = manager.googleClientID
        let clientSecret = clientSecretDraft
        Task {
            do {
                _ = try await manager.driveClient.connectInteractive(
                    clientID: clientID,
                    clientSecret: clientSecret
                )
                manager.refreshConnectionState()
                setStatus("Connected Google Drive (appDataFolder).", isError: false)
            } catch {
                setStatus("Google Drive sign-in failed: \(error.localizedDescription)", isError: true)
            }
            isWorking = false
        }
    }

    func disconnectGoogleDrive() {
        do {
            try manager.driveClient.disconnect()
            manager.refreshConnectionState()
            setStatus("Disconnected Google Drive.", isError: false)
        } catch {
            setStatus("Could not disconnect Google Drive.", isError: true)
        }
    }

    func backUpToGoogleDriveNow() {
        guard let delegate = NSApp.delegate as? AppDelegate,
              let passphrase = resolvedPassphraseForBackup() else { return }
        isWorking = true
        setStatus("Creating and uploading archive…", isError: false)
        let fileName = MacClippyCloudBackupManager.timestampedArchiveFileName()
        let tempArchiveURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        delegate.createArchiveBackup(at: tempArchiveURL, passphrase: passphrase, overwrite: true) { result in
            switch result {
            case .success:
                Task {
                    defer { try? FileManager.default.removeItem(at: tempArchiveURL) }
                    do {
                        let uploaded = try await manager.driveClient.uploadBackup(
                            fileURL: tempArchiveURL,
                            fileName: fileName
                        )
                        try? await manager.driveClient.pruneOldBackups(
                            keepLatest: MacClippyCloudBackupManager.defaultKeepLatest
                        )
                        manager.markBackupSucceeded()
                        setStatus("Uploaded \(uploaded.name) to Google Drive.", isError: false)
                    } catch {
                        setStatus("Google Drive upload failed: \(error.localizedDescription)", isError: true)
                    }
                    isWorking = false
                }
            case let .failure(error):
                try? FileManager.default.removeItem(at: tempArchiveURL)
                setStatus(MacClippyBackupPassphrasePrompt.userMessage(for: error), isError: true)
                isWorking = false
            }
        }
    }

    func openGoogleDrivePicker() {
        isWorking = true
        Task {
            do {
                googleBackups = try await manager.driveClient.listBackups()
                isGooglePickerPresented = true
            } catch {
                setStatus("Could not list Google Drive backups: \(error.localizedDescription)", isError: true)
            }
            isWorking = false
        }
    }

    func restoreFromGoogleDrive(_ file: MacClippyGoogleDriveBackupFile) {
        guard let delegate = NSApp.delegate as? AppDelegate,
              let passphrase = MacClippyBackupPassphrasePrompt.promptForUnlock() else { return }
        isWorking = true
        setStatus("Downloading \(file.name)…", isError: false)
        let tempArchiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Restore-\(UUID().uuidString)-\(file.name)")
        Task {
            do {
                try await manager.driveClient.downloadBackup(fileID: file.id, to: tempArchiveURL)
                delegate.restoreArchiveBackup(from: tempArchiveURL, passphrase: passphrase) { result in
                    try? FileManager.default.removeItem(at: tempArchiveURL)
                    isWorking = false
                    switch result {
                    case .success:
                        setStatus(MacClippyBackupSettingsPolicy.restoreSuccessMessage(), isError: false)
                    case let .failure(error):
                        setStatus(MacClippyBackupPassphrasePrompt.userMessage(for: error), isError: true)
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: tempArchiveURL)
                isWorking = false
                setStatus("Google Drive download failed: \(error.localizedDescription)", isError: true)
            }
        }
    }
}
