import AppKit
import MacClippyCore
import MacClippyPlatform

@MainActor
extension AppDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isIsolatedE2E else { return false }
        openSettingsWindow()
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard !isIsolatedE2E else { return false }
        openSettingsWindow()
        return true
    }

    func handleStartupFailure(_ error: Error) {
        rollbackStartup()
        MacClippyLog.record(
            category: .lifecycle,
            code: .startupFailed,
            operation: "application_startup",
            recoveryAction: "retry_startup",
            impact: "menu_bar_runtime_unavailable"
        )
        if !isIsolatedE2E {
            clipboardHotKey.unregister()
        }

        if isIsolatedE2E {
            NSApp.terminate(nil)
            return
        }

#if !MACCLIPPY_E2E
        if !isLaunchedByXCTest,
           case .missingKey? = error as? MacClippyKeychainError,
           let paths = try? startupStoragePaths() {
            DispatchQueue.main.async { [weak self] in
                self?.recoverMissingKeychainStartup(at: paths)
            }
            return
        }
#endif

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Mac Clippy could not start"
            alert.informativeText = "Mac Clippy could not initialize its local services. Retry now or close the app and try again."
            alert.addButton(withTitle: "Retry")
            alert.addButton(withTitle: "Close")
            if alert.runModal() == .alertFirstButtonReturn {
                self.retryStartup()
            } else {
                NSApp.terminate(nil)
            }
        }
    }

#if !MACCLIPPY_E2E
    private func recoverMissingKeychainStartup(at paths: MacClippyPaths) {
        MacClippyBackupPassphrasePrompt.presentMissingKeychainRecovery(
            onRestore: { [weak self] in
                self?.restoreArchiveAfterMissingKeychain(at: paths)
            },
            onStartFresh: { [weak self] in
                do {
                    try MacClippyBackupPassphrasePrompt.archiveUnreadableStorage(at: paths.rootURL)
                    self?.retryStartup()
                } catch {
                    self?.presentRecoveryFailureAlert(error.localizedDescription)
                }
            }
        )
    }

    private func restoreArchiveAfterMissingKeychain(at paths: MacClippyPaths) {
        guard let archiveURL = MacClippyBackupPassphrasePrompt.chooseArchiveURLForRecovery(),
              let passphrase = MacClippyBackupPassphrasePrompt.promptForUnlock() else {
            recoverMissingKeychainStartup(at: paths)
            return
        }
        do {
            let validation = try MacClippyBackup.validateArchive(at: archiveURL, passphrase: passphrase)
            guard MacClippyBackupSettingsPolicy.canRestore(validation) else {
                throw MacClippyBackupError.invalidManifest
            }
            try MacClippyBackupPassphrasePrompt.archiveUnreadableStorage(at: paths.rootURL)
            let targetKeySource = try MacClippyBackupKeySource.loadOrCreate(
                using: MacClippySystemKeychain(),
                requireExistingStorage: false
            )
            _ = try MacClippyBackup.installArchiveIntoLiveRoot(
                from: archiveURL,
                passphrase: passphrase,
                liveRootURL: paths.rootURL,
                targetKeySource: targetKeySource
            )
            try MacClippyBackup.finalizePendingRestore(at: paths.rootURL)
            retryStartup()
        } catch {
            presentRecoveryFailureAlert(
                (error as? MacClippyBackupError).map(MacClippyBackupSettingsPolicy.message(for:))
                    ?? error.localizedDescription
            )
        }
    }

    private func presentRecoveryFailureAlert(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recovery Did Not Complete"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        if let paths = try? startupStoragePaths() {
            recoverMissingKeychainStartup(at: paths)
        } else {
            NSApp.terminate(nil)
        }
    }
#endif

    func retryStartup() {
        recoverPendingRestoreAndStart()
    }

    func refreshPermissionDependentFeatures() {
        runtime?.refreshPermissionDependentFeatures()
    }

    func openSettingsWindowFromDock() {
        openSettingsWindow()
    }

    func refreshStorageUsage(
        completion: @escaping @MainActor @Sendable (MacClippyStorageUsage?) -> Void
    ) {
        guard let runtime else {
            completion(nil)
            return
        }
        let generation = maintenanceGeneration
        DispatchQueue.global(qos: .utility).async {
            let usage = try? runtime.storageUsage()
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation, self.runtime === runtime else { return }
                completion(usage)
            }
        }
    }

    func compressOldImages(
        completion: @escaping @MainActor @Sendable (Result<MacClippyImageCompressReport, Error>) -> Void
    ) {
        guard let runtime else {
            completion(.failure(StartupError.runtimeUnavailable))
            return
        }
        let generation = maintenanceGeneration
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try runtime.compressOldImages() }
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation, self.runtime === runtime else { return }
                completion(result)
            }
        }
    }

    func refreshStorageHealth(
        completion: @escaping @MainActor @Sendable ([String: MacClippyDatabaseHealthReport]) -> Void
    ) {
        guard let runtime else {
            completion([:])
            return
        }
        let generation = maintenanceGeneration
        DispatchQueue.global(qos: .utility).async {
            let health = runtime.storageHealth(mode: .full)
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation, self.runtime === runtime else { return }
                completion(health)
            }
        }
    }

    #if DEBUG
    func insertRemoteClipboardSample() throws {
        guard let runtime else { throw StartupError.runtimeUnavailable }
        _ = try runtime.insertRemoteClipboardSample()
    }
    #endif

    func exportDiagnostics(
        to url: URL,
        completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
    ) {
        guard let runtime else {
            completion(.failure(StartupError.runtimeUnavailable))
            return
        }
        let generation = maintenanceGeneration
        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                let snapshot = try runtime.diagnosticsStorageSnapshot()
                try MacClippyDiagnosticsExporter.export(
                    to: url,
                    defaults: runtime.preferencesDefaults,
                    paths: runtime.paths,
                    storageSnapshot: snapshot
                )
            }
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation, self.runtime === runtime else { return }
                completion(result)
            }
        }
    }

    func repairSearchIndex(
        completion: @escaping @MainActor @Sendable (Result<MacClippySearchRepairReport, Error>) -> Void
    ) {
        guard let runtime else {
            completion(.failure(StartupError.runtimeUnavailable))
            return
        }
        guard let lifecycleToken = runtime.activeLifecycleToken() else {
            completion(.failure(StartupError.runtimeUnavailable))
            return
        }
        let generation = maintenanceGeneration
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try runtime.repairSearchIndex(for: lifecycleToken) }
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation, self.runtime === runtime else { return }
                completion(result)
            }
        }
    }

    func createBackup(
        at url: URL,
        completion: @escaping @MainActor @Sendable (Result<MacClippyBackupManifest, Error>) -> Void
    ) {
        guard let runtime else {
            completion(.failure(StartupError.runtimeUnavailable))
            return
        }
        let generation = maintenanceGeneration
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try runtime.createBackup(at: url) }
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation, self.runtime === runtime else { return }
                completion(result)
            }
        }
    }

    func createArchiveBackup(
        at url: URL,
        passphrase: String,
        overwrite: Bool = false,
        completion: @escaping @MainActor @Sendable (Result<MacClippyBackupManifest, Error>) -> Void
    ) {
        guard let runtime else {
            completion(.failure(StartupError.runtimeUnavailable))
            return
        }
        let generation = maintenanceGeneration
        DispatchQueue.global(qos: .utility).async {
            let result = Result {
                try runtime.createArchiveBackup(at: url, passphrase: passphrase, overwrite: overwrite)
            }
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation, self.runtime === runtime else { return }
                completion(result)
            }
        }
    }

    func restoreArchiveBackup(
        from archiveURL: URL,
        passphrase: String,
        completion: @escaping @MainActor @Sendable (Result<MacClippyBackupValidation, Error>) -> Void
    ) {
        guard let runtime else {
            completion(.failure(MacClippyBackupError.keyRequired))
            return
        }
        let keySource = runtime.clipboardStore.backupKeySource
        let generation = maintenanceGeneration
        DispatchQueue.global(qos: .utility).async {
            let validationResult = Result {
                try MacClippyBackup.validateArchive(at: archiveURL, passphrase: passphrase)
            }
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation else { return }
                switch validationResult {
                case let .success(validation):
                    guard MacClippyBackupSettingsPolicy.canRestore(validation) else {
                        completion(.failure(MacClippyBackupError.invalidManifest))
                        return
                    }
                    self.installArchiveBackup(
                        from: archiveURL,
                        passphrase: passphrase,
                        targetKeySource: keySource,
                        completion: completion
                    )
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        }
    }

    func restoreBackup(
        from snapshotURL: URL,
        completion: @escaping @MainActor @Sendable (Result<MacClippyBackupValidation, Error>) -> Void
    ) {
        guard let runtime else {
            completion(.failure(MacClippyBackupError.keyRequired))
            return
        }
        let keySource = runtime.clipboardStore.backupKeySource
        let generation = maintenanceGeneration
        DispatchQueue.global(qos: .utility).async {
            let validationResult = Result {
                try MacClippyBackup.validate(at: snapshotURL, keySource: keySource)
            }
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation else { return }
                switch validationResult {
                case let .success(validation):
                    guard MacClippyBackupSettingsPolicy.canRestore(validation) else {
                        let error = validation.keyCompatible
                            ? MacClippyBackupError.invalidManifest
                            : MacClippyBackupError.keyMismatch
                        completion(.failure(error))
                        return
                    }
                    self.installValidatedBackup(from: snapshotURL, keySource: keySource, completion: completion)
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        }
    }

    func deleteUnpinnedHistory(
        completion: @escaping @MainActor @Sendable (Result<MacClippyBatchDeleteResult, Error>) -> Void
    ) {
        guard let runtime else {
            completion(.failure(StartupError.runtimeUnavailable))
            return
        }
        guard let lifecycleToken = runtime.activeLifecycleToken() else {
            completion(.failure(StartupError.runtimeUnavailable))
            return
        }
        let generation = maintenanceGeneration
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try runtime.deleteUnpinnedHistory(for: lifecycleToken) }
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation, self.runtime === runtime else { return }
                completion(result)
            }
        }
    }

    func configureStatusItem(_ button: NSStatusBarButton) {
        button.title = ""
        button.image = MacClippyStatusItemIconPolicy.makeImage()
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.toolTip = "Mac Clippy"
        button.setAccessibilityLabel("Mac Clippy")
        button.setAccessibilityRole(.button)
        button.setAccessibilityHelp("Open clipboard history")
        button.target = self
        button.action = #selector(handleStatusItemAction(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    func loadBundledApplicationIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
