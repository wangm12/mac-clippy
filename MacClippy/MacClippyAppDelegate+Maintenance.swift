import AppKit

import MacClippyCore
import MacClippyPlatform

@MainActor
extension AppDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsWindow()
        return true
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        openSettingsWindow()
        return true
    }

    func handleStartupFailure(_: Error) {
        rollbackStartup()
        MacClippyLog.record(
            category: .lifecycle,
            code: .startupFailed,
            operation: "application_startup",
            recoveryAction: "retry_startup",
            impact: "menu_bar_runtime_unavailable"
        )
        clipboardHotKey.unregister()

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

    func retryStartup() {
        do {
            try start()
        } catch {
            handleStartupFailure(error)
        }
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
            let health = runtime.storageHealth()
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
                try MacClippyDiagnosticsExporter.export(to: url, storageSnapshot: snapshot)
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

    func restoreBackup(
        from snapshotURL: URL,
        completion: @escaping @MainActor @Sendable (Result<MacClippyBackupValidation, Error>) -> Void
    ) {
        let generation = maintenanceGeneration
        DispatchQueue.global(qos: .utility).async {
            let validationResult = Result { try MacClippyBackup.validate(at: snapshotURL) }
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation else { return }
                switch validationResult {
                case let .success(validation):
                    guard MacClippyBackupSettingsPolicy.canRestore(validation) else {
                        completion(.failure(MacClippyBackupError.invalidManifest))
                        return
                    }
                    self.installValidatedBackup(from: snapshotURL, completion: completion)
                case let .failure(error):
                    completion(.failure(error))
                }
            }
        }
    }

    private func installValidatedBackup(
        from snapshotURL: URL,
        completion: @escaping @MainActor @Sendable (Result<MacClippyBackupValidation, Error>) -> Void
    ) {
        rollbackStartup()
        let generation = maintenanceGeneration
        DispatchQueue.global(qos: .utility).async {
            let installResult = Result {
                let paths = try MacClippyPaths()
                return try MacClippyBackup.installIntoLiveRoot(
                    from: snapshotURL,
                    liveRootURL: paths.rootURL
                )
            }
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation else { return }
                switch installResult {
                case let .success(installed):
                    do {
                        try self.start()
                        completion(.success(installed))
                    } catch {
                        self.handleStartupFailure(error)
                        completion(.failure(error))
                    }
                case let .failure(error):
                    do {
                        try self.start()
                    } catch {
                        self.handleStartupFailure(error)
                    }
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
        button.action = #selector(toggleDock(_:))
    }

    func loadBundledApplicationIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
