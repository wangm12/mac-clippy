import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    func scheduleDeferredBlobDelete(_ blobID: String) {
        maintenanceQueue.async { [weak self] in
            guard let self, let lifecycleToken = self.activeLifecycleToken() else { return }
            do {
                try self.performCurrentLifecycleCommit(lifecycleToken) {
                    // A deferred file may have gained a new owner since the
                    // original cleanup decision. Revalidate under the short
                    // storage fence before asking BlobStore to unlink it.
                    guard try self.clipboardStore.unreferencedBlobIDsWithoutBackfill([blobID]).contains(blobID) else {
                        return
                    }
                    try self.blobStore.delete(id: blobID)
                }
            } catch is CancellationError {
                return
            } catch {
                self.storageDegradedReasons.insert("orphan-blob-cleanup-failed")
                MacClippyLog.record(
                    category: .blob,
                    code: .blobCleanupFailed,
                    operation: "deferred_blob_cleanup",
                    recoveryAction: "run_storage_reconciliation",
                    impact: "possible_orphan_blob"
                )
            }
        }
    }

    func markSearchRepairNeededLocked() {
        storageDegradedReasons.insert("fts-repair-needed")
        do {
            try searchStore.markRepairNeeded()
        } catch {
            MacClippyLog.record(
                category: .storage,
                code: .databaseHealthFailed,
                operation: "persist_fts_repair_marker",
                recoveryAction: "export_diagnostics_and_repair_storage",
                impact: "fts_repair_state_not_persisted"
            )
        }
    }

    /// Replays deletion operations left in the clipboard database by a force
    /// quit or a secondary-store/blob failure. Every step is idempotent; the
    /// journal is removed only after all known side effects have completed.
    func replayPendingDeletionsLocked(shouldContinue: () -> Bool = { true }) throws {
        while true {
            let operationIDs = try clipboardStore.pendingDeletionOperationIDs(limit: 64)
            guard !operationIDs.isEmpty else { return }
            for operationID in operationIDs {
                guard shouldContinue() else { throw CancellationError() }
                try replayDeletionOperationLocked(
                    operationID: operationID,
                    shouldContinue: shouldContinue
                )
            }
        }
    }

    private func replayDeletionOperationLocked(
        operationID: String,
        shouldContinue: () -> Bool
    ) throws {
        try replayDeletedRecordsLocked(operationID: operationID, shouldContinue: shouldContinue)
        try replayPinboardReferencesLocked(operationID: operationID, shouldContinue: shouldContinue)

        var blobIDs = Set<String>()
        var blobOffset = 0
        while true {
            let page = try clipboardStore.deletionBlobIDs(
                operationID: operationID,
                offset: blobOffset
            )
            guard !page.isEmpty else { break }
            blobIDs.formUnion(page)
            guard page.count == 256 else { break }
            blobOffset += page.count
        }
        let unreferenced = try clipboardStore.unreferencedBlobIDsWithoutBackfill(
            blobIDs,
            shouldContinue: shouldContinue
        )
        for blobID in unreferenced {
            guard shouldContinue() else { throw CancellationError() }
            try blobStore.delete(id: blobID)
        }
        try clipboardStore.completeDeletion(operationID: operationID)
    }

    private func replayDeletedRecordsLocked(
        operationID: String,
        shouldContinue: () -> Bool
    ) throws {
        var offset = 0
        while true {
            let recordIDs = try clipboardStore.deletionRecordIDs(
                operationID: operationID,
                offset: offset
            )
            guard !recordIDs.isEmpty else { return }
            for id in recordIDs {
                guard shouldContinue() else { throw CancellationError() }
                try searchStore.remove(kind: .clipboardItem, id: id)
                try clipboardStore.delete(id: id)
                thumbnailDiskCache.remove(id: id)
            }
            guard recordIDs.count == 256 else { return }
            offset += recordIDs.count
        }
    }

    private func replayPinboardReferencesLocked(
        operationID: String,
        shouldContinue: () -> Bool
    ) throws {
        let boards = try pinboardStore.listStrict()
        var offset = 0
        while true {
            let recordIDs = try clipboardStore.deletionRecordIDs(
                operationID: operationID,
                offset: offset
            )
            guard !recordIDs.isEmpty else { return }
            for board in boards {
                guard shouldContinue() else { throw CancellationError() }
                for id in recordIDs where board.itemIDs.contains(id) {
                    try pinboardStore.removeItem(id, from: board.id)
                }
            }
            guard recordIDs.count == 256 else { return }
            offset += recordIDs.count
        }
    }

}
