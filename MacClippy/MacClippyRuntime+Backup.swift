import Foundation

import MacClippyCore

extension MacClippyRuntime {
    func cancelBulkMaintenanceIO() {
        MacClippyMaintenanceIOCoordinator.shared.cancelOperations(at: paths.rootURL)
    }

    func beginRestoreMaintenanceIOBarrier() -> MacClippyMaintenanceIOCoordinator.RestoreBarrier {
        MacClippyMaintenanceIOCoordinator.shared.beginRestore(at: paths.rootURL)
    }

    func createBackup(at destinationURL: URL) throws -> MacClippyBackupManifest {
        let coordinator = MacClippyMaintenanceIOCoordinator.shared
        guard let operation = coordinator.beginOperation(at: paths.rootURL, kind: .backup) else {
            throw CancellationError()
        }
        defer { operation.finish() }

        let sources = [
            MacClippyBackupSource(name: "clipboard", database: databases[0]),
            MacClippyBackupSource(name: "search", database: databases[1]),
            MacClippyBackupSource(name: "pinboards", database: databases[2]),
            MacClippyBackupSource(name: "snippets", database: databases[3])
        ]
        let snapshot = try withStoreLock { () throws -> (
            databases: [MacClippyBackupReadSnapshot],
            blobLease: MacClippyBlobLease
        ) in
            guard !operation.isCancelled else { throw CancellationError() }
            let databaseSnapshots = try MacClippyBackup.beginReadSnapshots(sources: sources)
            let blobLease = try blobStore.acquireRootReadLease()
            return (databaseSnapshots, blobLease)
        }
        defer {
            snapshot.databases.forEach { $0.close() }
            snapshot.blobLease.release()
        }

        #if DEBUG
            MacClippyMaintenanceIOTestHooks.afterBackupSnapshots()
        #endif
        return try MacClippyBackup.create(
            snapshots: snapshot.databases,
            blobsURL: paths.blobsURL,
            keySource: clipboardStore.backupKeySource,
            at: destinationURL,
            shouldContinue: { !operation.isCancelled }
        )
    }
}
