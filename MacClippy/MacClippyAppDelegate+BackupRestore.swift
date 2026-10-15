import AppKit
import MacClippyCore
import MacClippyPlatform

@MainActor
extension AppDelegate {
    func makeRuntimeForStartup(allowPendingRestore: Bool) throws -> MacClippyRuntime {
#if MACCLIPPY_E2E
        guard let e2eIsolation, let e2eRecipient, let e2ePasteBarrier else {
            throw MacClippyE2EIsolationError.invalidConfiguration
        }
        let paths = e2eIsolation.paths
        if !allowPendingRestore {
            try MacClippyBackup.recoverPendingRestore(at: paths.rootURL)
        }
        return try MacClippyRuntime(
            paths: paths,
            keychain: e2eIsolation.keychain,
            observer: e2eIsolation.makeObserver(),
            pasteInjector: e2eIsolation.makePasteInjector(
                recipient: e2eRecipient,
                barrier: e2ePasteBarrier
            ),
            pasteboardWriteSentinel: e2eIsolation.pasteboardWriteSentinel,
            managesInjectedObserverPreferences: true,
            retentionPolicyOverride: RetentionPolicy(
                maxItems: e2eIsolation.retentionMaxItems,
                maxAge: nil,
                maxImageBytes: MacClippyRetentionPreferences.defaultMaxImageMegabytes * 1_024 * 1_024,
                maxTotalBytes: MacClippyRetentionPreferences.defaultMaxHistoryMegabytes * 1_024 * 1_024
            ),
            enableSnippetExpansion: false,
            preferencesDefaults: e2eIsolation.defaults
        )
#else
        if !allowPendingRestore {
            let paths = try MacClippyPaths()
            try MacClippyBackup.recoverPendingRestore(at: paths.rootURL)
        }
        return try MacClippyRuntime()
#endif
    }

    func installValidatedBackup(
        from snapshotURL: URL,
        keySource: MacClippyBackupKeySource,
        completion: @escaping @MainActor @Sendable (Result<MacClippyBackupValidation, Error>) -> Void
    ) {
        guard let oldRuntime = runtime else {
            completion(.failure(StartupError.runtimeUnavailable))
            return
        }

        rollbackStartup()
        let generation = maintenanceGeneration
        let liveRootURL = oldRuntime.paths.rootURL
        DispatchQueue.global(qos: .utility).async {
            let restoreBarrier = oldRuntime.beginRestoreMaintenanceIOBarrier()
            defer { withExtendedLifetime(restoreBarrier) {} }
            let result = Result {
                try oldRuntime.closeStorageForRestore()
                return try MacClippyBackup.installIntoLiveRoot(
                    from: snapshotURL,
                    liveRootURL: liveRootURL,
                    keySource: keySource
                )
            }
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation else { return }
                self.finishBackupInstall(result, rootURL: liveRootURL, completion: completion)
            }
        }
    }

    private func finishBackupInstall(
        _ result: Result<MacClippyBackupValidation, Error>,
        rootURL: URL,
        completion: @escaping @MainActor @Sendable (Result<MacClippyBackupValidation, Error>) -> Void
    ) {
        switch result {
        case let .success(validation):
            startRestoredRuntime(validation, rootURL: rootURL, completion: completion)
        case let .failure(error):
            recoverPreviousRuntime(after: error, rootURL: rootURL, completion: completion)
        }
    }

    private func startRestoredRuntime(
        _ validation: MacClippyBackupValidation,
        rootURL: URL,
        completion: @escaping @MainActor @Sendable (Result<MacClippyBackupValidation, Error>) -> Void
    ) {
        do {
            try start(allowPendingRestore: true)
            guard let newRuntime = runtime else { throw StartupError.runtimeUnavailable }
            finalizeRestore(validation, rootURL: newRuntime.paths.rootURL, completion: completion)
        } catch {
            let failedRuntime = runtime
            rollbackStartup()
            recoverPreviousRuntime(
                after: error,
                rootURL: rootURL,
                runtimeToClose: failedRuntime,
                completion: completion
            )
        }
    }

    private func finalizeRestore(
        _ validation: MacClippyBackupValidation,
        rootURL: URL,
        completion: @escaping @MainActor @Sendable (Result<MacClippyBackupValidation, Error>) -> Void
    ) {
        let generation = maintenanceGeneration
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try MacClippyBackup.finalizePendingRestore(at: rootURL) }
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation else { return }
                switch result {
                case .success:
                    completion(.success(validation))
                case let .failure(error):
                    let failedRuntime = self.runtime
                    self.rollbackStartup()
                    self.recoverPreviousRuntime(
                        after: error,
                        rootURL: rootURL,
                        runtimeToClose: failedRuntime,
                        completion: completion
                    )
                }
            }
        }
    }

    private func recoverPreviousRuntime(
        after originalError: Error,
        rootURL: URL,
        runtimeToClose: MacClippyRuntime? = nil,
        completion: @escaping @MainActor @Sendable (Result<MacClippyBackupValidation, Error>) -> Void
    ) {
        let generation = maintenanceGeneration
        DispatchQueue.global(qos: .utility).async {
            let recovery = Result {
                if let runtimeToClose {
                    let restoreBarrier = runtimeToClose.beginRestoreMaintenanceIOBarrier()
                    defer { withExtendedLifetime(restoreBarrier) {} }
                    try runtimeToClose.closeStorageForRestore()
                }
                try MacClippyBackup.recoverPendingRestore(at: rootURL)
            }
            DispatchQueue.main.async {
                guard self.maintenanceGeneration == generation else { return }
                do {
                    try recovery.get()
                    try self.start(allowPendingRestore: true)
                } catch {
                    self.handleStartupFailure(error)
                }
                completion(.failure(originalError))
            }
        }
    }
}
