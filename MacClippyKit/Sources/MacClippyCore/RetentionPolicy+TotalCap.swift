import Foundation

private struct MacClippyTotalStorageAccounting {
    var totalBytes = 0
    var countedBlobIDs = Set<String>()
    var blobReferenceCounts: [String: Int] = [:]
    var blobByteCounts: [String: Int] = [:]
}

private struct MacClippyTotalDeletionBatch {
    let ids: [RecordID]
    let expectedFootprints: [RecordID: (modified: Date, footprint: MacClippyStoredPayloadFootprint)]
}

private struct MacClippyTotalRetentionContext {
    let store: ClipboardStore
    let blobs: BlobStore
    let search: SearchStore
    let protectedIDs: Set<RecordID>
    let accounting: MacClippyTotalStorageAccounting
    let maxTotalBytes: Int
    let shouldContinue: () -> Bool
    let withCommitFence: (() throws -> Void) throws -> Void
    let protectedIDsProvider: (() throws -> Set<RecordID>)?
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
        guard let maxTotalBytes else { return }
        guard shouldContinue() else { return }
        var accounting = MacClippyTotalStorageAccounting()
        try Self.buildTotalStorageAccounting(
            store: store,
            blobs: blobs,
            protectedIDs: protectedIDs,
            accounting: &accounting,
            shouldContinue: shouldContinue
        )
        guard shouldContinue(), accounting.totalBytes > maxTotalBytes else { return }

        let context = MacClippyTotalRetentionContext(
            store: store,
            blobs: blobs,
            search: search,
            protectedIDs: protectedIDs,
            accounting: accounting,
            maxTotalBytes: maxTotalBytes,
            shouldContinue: shouldContinue,
            withCommitFence: withCommitFence,
            protectedIDsProvider: protectedIDsProvider
        )

        var remaining = accounting.totalBytes
        var remainingBlobReferences = accounting.blobReferenceCounts
        var madeProgress = true
        while remaining > maxTotalBytes, madeProgress, shouldContinue() {
            madeProgress = false
            try Self.deleteTotalPageCandidates(
                context: context,
                remaining: &remaining,
                remainingBlobReferences: &remainingBlobReferences,
                madeProgress: &madeProgress
            )
        }
    }

    private static func buildTotalStorageAccounting(
        store: ClipboardStore,
        blobs: BlobStore,
        protectedIDs: Set<RecordID>,
        accounting: inout MacClippyTotalStorageAccounting,
        shouldContinue: @escaping () -> Bool
    ) throws {
        try scanMetadataPagesOldest(store: store, shouldContinue: shouldContinue) { page in
            for meta in page {
                let footprint = try store.storageFootprint(for: meta.id)
                for blobID in footprint.blobIDs {
                    accounting.blobReferenceCounts[blobID, default: 0] += 1
                    if accounting.blobByteCounts[blobID] == nil {
                        accounting.blobByteCounts[blobID] = try blobs.byteSizeChecked(id: blobID)
                    }
                }
                guard !protectedIDs.contains(meta.id) else { continue }
                accounting.totalBytes += footprint.inlineBytes
                for blobID in footprint.blobIDs where accounting.countedBlobIDs.insert(blobID).inserted {
                    accounting.totalBytes += accounting.blobByteCounts[blobID] ?? 0
                }
            }
            return false
        }
    }

    private static func deleteTotalPageCandidates(
        context: MacClippyTotalRetentionContext,
        remaining: inout Int,
        remainingBlobReferences: inout [String: Int],
        madeProgress: inout Bool
    ) throws {
        try scanMetadataPagesOldest(store: context.store, shouldContinue: context.shouldContinue) { page in
            let candidates = page.filter { !context.protectedIDs.contains($0.id) }
            var candidateIndex = 0
            while remaining > context.maxTotalBytes, candidateIndex < candidates.count {
                guard let batch = try makeTotalDeletionBatch(
                    candidates: candidates,
                    candidateIndex: &candidateIndex,
                    context: context,
                    remaining: remaining,
                    remainingBlobReferences: remainingBlobReferences
                ) else { break }

                let deletedIDs = try deleteRecords(
                    batch.ids,
                    store: context.store,
                    blobs: context.blobs,
                    search: context.search,
                    protectedIDsProvider: context.protectedIDsProvider,
                    shouldContinue: context.shouldContinue,
                    withCommitFence: context.withCommitFence,
                    revalidateIDs: { ids in
                        try revalidatedTotalIDs(ids, expected: batch.expectedFootprints, store: context.store)
                    }
                )
                for id in deletedIDs {
                    guard let footprint = batch.expectedFootprints[id]?.footprint else { continue }
                    remaining -= footprint.inlineBytes
                    for blobID in footprint.blobIDs {
                        remainingBlobReferences[blobID, default: 0] -= 1
                        if remainingBlobReferences[blobID] == 0 {
                            remaining -= context.accounting.blobByteCounts[blobID] ?? 0
                        }
                    }
                }
                madeProgress = madeProgress || !deletedIDs.isEmpty
            }
            return remaining <= context.maxTotalBytes
        }
    }

    private static func makeTotalDeletionBatch(
        candidates: [ClipboardItemMeta],
        candidateIndex: inout Int,
        context: MacClippyTotalRetentionContext,
        remaining: Int,
        remainingBlobReferences: [String: Int]
    ) throws -> MacClippyTotalDeletionBatch? {
        var ids: [RecordID] = []
        var expectedFootprints: [RecordID: (modified: Date, footprint: MacClippyStoredPayloadFootprint)] = [:]
        var plannedRemaining = remaining
        var plannedBlobReferences = remainingBlobReferences
        while candidateIndex < candidates.count, plannedRemaining > context.maxTotalBytes {
            let meta = candidates[candidateIndex]
            candidateIndex += 1
            let footprint = try context.store.storageFootprint(for: meta.id)
            let releasableBlobBytes = footprint.blobIDs.reduce(into: 0) { bytes, blobID in
                guard plannedBlobReferences[blobID] == 1 else { return }
                bytes += context.accounting.blobByteCounts[blobID] ?? 0
            }
            let bytes = footprint.inlineBytes + releasableBlobBytes
            guard bytes > 0 else { continue }
            ids.append(meta.id)
            expectedFootprints[meta.id] = (meta.modified, footprint)
            plannedRemaining -= bytes
            for blobID in footprint.blobIDs {
                plannedBlobReferences[blobID, default: 0] -= 1
            }
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
                  expectedFootprint.modified == meta.modified
            else {
                return nil
            }
            return try store.storageFootprint(for: meta.id) == expectedFootprint.footprint
                ? meta.id
                : nil
        }
    }
}
