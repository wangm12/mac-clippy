import Foundation

private struct MacClippyTotalDeletionBatch {
    let ids: [RecordID]
    let expectedFootprints: [RecordID: (modified: Date, footprint: MacClippyStoredPayloadFootprint)]
}

private struct MacClippyTotalRetentionContext {
    let store: ClipboardStore
    let blobs: BlobStore
    let search: SearchStore
    let protectedIDs: Set<RecordID>
    let maxTotalBytes: Int
    let shouldContinue: () -> Bool
    let withCommitFence: (() throws -> Void) throws -> Void
    let protectedIDsProvider: (() throws -> Set<RecordID>)?
}

private struct MacClippyTotalCommitOutcome {
    let deletion: MacClippyRetentionDeletionResult
    let revision: Int64
}

extension MacClippyRetentionPolicy {
    public func enforceTotalCap(
        store: ClipboardStore,
        blobs: BlobStore,
        search: SearchStore,
        protectedIDs: Set<RecordID>,
        shouldContinue: @escaping () -> Bool = { true },
        withCommitFence: @escaping ((() throws -> Void) throws -> Void) = { operation in try operation() },
        protectedIDsProvider: (() throws -> Set<RecordID>)? = nil
    ) throws {
        guard let maxTotalBytes, shouldContinue() else { return }
        let context = MacClippyTotalRetentionContext(
            store: store, blobs: blobs, search: search, protectedIDs: protectedIDs,
            maxTotalBytes: max(0, maxTotalBytes), shouldContinue: shouldContinue,
            withCommitFence: withCommitFence, protectedIDsProvider: protectedIDsProvider
        )
        guard var accounting = try Self.refreshedTotalAccounting(context) else { return }
        var restarts = 0
        while accounting.totalBytes > context.maxTotalBytes, shouldContinue() {
            var madeProgress = false
            let invalidated = try Self.deleteTotalPageCandidates(
                context: context, accounting: &accounting, madeProgress: &madeProgress
            )
            if invalidated {
                restarts += 1
                guard restarts <= 3, let refreshed = try Self.refreshedTotalAccounting(context) else { return }
                accounting = refreshed
            } else if !madeProgress {
                return
            }
        }
    }

    private static func refreshedTotalAccounting(
        _ context: MacClippyTotalRetentionContext
    ) throws -> MacClippyTotalStorageAccounting? {
        try totalStorageAccounting(
            store: context.store, blobs: context.blobs, protectedIDs: context.protectedIDs,
            protectedIDsProvider: context.protectedIDsProvider, shouldContinue: context.shouldContinue
        )
    }

    private static func deleteTotalPageCandidates(
        context: MacClippyTotalRetentionContext,
        accounting: inout MacClippyTotalStorageAccounting,
        madeProgress: inout Bool
    ) throws -> Bool {
        var invalidated = false
        try scanMetadataPagesOldest(store: context.store, shouldContinue: context.shouldContinue) { page in
            let candidates = page.filter { !accounting.protectedIDs.contains($0.id) }
            var candidateIndex = 0
            while accounting.totalBytes > context.maxTotalBytes, candidateIndex < candidates.count {
                let batch: MacClippyTotalDeletionBatch?
                do {
                    batch = try makeTotalDeletionBatch(
                        candidates: candidates, candidateIndex: &candidateIndex,
                        context: context, accounting: accounting
                    )
                } catch MacClippyStoreError.recordNotFound {
                    guard try context.store.recordsRevision() != accounting.revision else {
                        throw MacClippyStoreError.recordNotFound
                    }
                    invalidated = true
                    return true
                }
                guard let batch else { break }
                guard let outcome = try commitTotalDeletionBatch(batch, context: context, accounting: accounting) else {
                    invalidated = true
                    return true
                }
                for id in outcome.deletion.recordIDs {
                    if let footprint = batch.expectedFootprints[id]?.footprint { accounting.remove(footprint) }
                }
                accounting.revision = outcome.revision
                madeProgress = madeProgress || !outcome.deletion.recordIDs.isEmpty
            }
            return accounting.totalBytes <= context.maxTotalBytes
        }
        return invalidated
    }

    private static func commitTotalDeletionBatch(
        _ batch: MacClippyTotalDeletionBatch,
        context: MacClippyTotalRetentionContext,
        accounting: MacClippyTotalStorageAccounting
    ) throws -> MacClippyTotalCommitOutcome? {
        var revisionAfter: Int64?
        let deletion = try deleteRecords(
            batch.ids, store: context.store, blobs: context.blobs, search: context.search,
            protectedIDsProvider: context.protectedIDsProvider, shouldContinue: context.shouldContinue,
            withCommitFence: { operation in
                try context.withCommitFence {
                    guard context.shouldContinue() else { return }
                    let protectedIDs = try context.protectedIDsProvider?() ?? context.protectedIDs
                    guard try context.store.recordsRevision() == accounting.revision,
                          protectedIDs == accounting.protectedIDs else { return }
                    // Validate the whole budget before deleting any member of a
                    // planned batch. Ownership or pins may have changed at the fence.
                    try operation()
                    revisionAfter = try context.store.recordsRevision()
                }
            },
            revalidateIDs: { ids in
                try revalidatedTotalIDs(ids, expected: batch.expectedFootprints, store: context.store)
            }
        )
        guard let revisionAfter else { return nil }
        return MacClippyTotalCommitOutcome(deletion: deletion, revision: revisionAfter)
    }

    private static func makeTotalDeletionBatch(
        candidates: [ClipboardItemMeta],
        candidateIndex: inout Int,
        context: MacClippyTotalRetentionContext,
        accounting: MacClippyTotalStorageAccounting
    ) throws -> MacClippyTotalDeletionBatch? {
        var ids: [RecordID] = []
        var expectedFootprints: [RecordID: (modified: Date, footprint: MacClippyStoredPayloadFootprint)] = [:]
        var planned = accounting
        while candidateIndex < candidates.count, planned.totalBytes > context.maxTotalBytes, context.shouldContinue() {
            let meta = candidates[candidateIndex]
            candidateIndex += 1
            let footprint = try context.store.storageFootprint(for: meta.id)
            guard footprint.inlineBytes > 0 || !footprint.blobIDs.isEmpty else { continue }
            ids.append(meta.id)
            expectedFootprints[meta.id] = (meta.modified, footprint)
            planned.remove(footprint)
        }
        guard !ids.isEmpty else { return nil }
        return MacClippyTotalDeletionBatch(ids: ids, expectedFootprints: expectedFootprints)
    }

    private static func revalidatedTotalIDs(
        _ ids: [RecordID],
        expected: [RecordID: (modified: Date, footprint: MacClippyStoredPayloadFootprint)],
        store: ClipboardStore
    ) throws -> [RecordID] {
        let currentMetas = try store.metas(for: ids)
        return try currentMetas.compactMap { meta in
            guard let expectedFootprint = expected[meta.id],
                  expectedFootprint.modified == meta.modified else { return nil }
            return try store.storageFootprint(for: meta.id) == expectedFootprint.footprint ? meta.id : nil
        }
    }
}
