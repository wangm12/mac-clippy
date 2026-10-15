import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    func runStorageReconciliation(
        for lifecycleToken: MacClippyRuntimeLifecycleToken
    ) throws -> (result: MacClippyReconciliation.Result, ftsRepairSucceeded: Bool) {
        try clipboardStore.authenticateOwnedBlobReferenceIndex(shouldContinue: { [weak self] in
            self?.isCurrentLifecycleToken(lifecycleToken) ?? false
        })
        try performCurrentLifecycleCommit(lifecycleToken) {
            try replayPendingDeletionsLocked(shouldContinue: {
                self.isCurrentLifecycleToken(lifecycleToken)
            })
        }
        let result = try MacClippyReconciliation.reconcile(
            store: clipboardStore,
            search: searchStore,
            blobs: blobStore,
            shouldContinue: { [weak self] in
                self?.isCurrentLifecycleToken(lifecycleToken) ?? false
            },
            deleteBlob: { [weak self, blobStore] id in
                guard let self else { throw CancellationError() }
                try self.performCurrentLifecycleCommit(lifecycleToken) {
                    // Reconciliation's reachability pass can race with a
                    // capture. Re-check while the lifecycle/store fence is
                    // held immediately before deleting the external file.
                    guard try !self.clipboardStore.isBlobReferenced(id) else { return }
                    try blobStore.delete(id: id)
                }
            },
            deleteFTS: { [weak self, searchStore] id in
                guard let self else { throw CancellationError() }
                try self.performCurrentLifecycleCommit(lifecycleToken) {
                    try searchStore.remove(kind: .clipboardItem, id: id)
                }
            },
            isBlobStillUnreferenced: { [clipboardStore] id in
                try !clipboardStore.isBlobReferenced(id)
            }
        )
        let ftsRepairSucceeded = try repairSearchIndexIfNeeded(for: result, lifecycleToken: lifecycleToken)
        return (result, ftsRepairSucceeded)
    }

}
