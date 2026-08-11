import Foundation

private struct MacClippyExpectedImageFootprint {
    let modified: Date
    let blobID: String
    let byteCount: Int
}

private struct MacClippyImageRetentionContext {
    let store: ClipboardStore
    let blobs: BlobStore
    let search: SearchStore
    let protectedIDs: Set<RecordID>
    let maxImageBytes: Int
    let shouldContinue: () -> Bool
    let withCommitFence: (() throws -> Void) throws -> Void
    let protectedIDsProvider: (() throws -> Set<RecordID>)?
}

extension MacClippyRetentionPolicy {
    public func enforceImageCap(
        store: ClipboardStore,
        blobs: BlobStore,
        search: SearchStore,
        protectedIDs: Set<RecordID>,
        shouldContinue: @escaping () -> Bool = { true },
        withCommitFence: @escaping ((() throws -> Void) throws -> Void) = { operation in try operation() },
        protectedIDsProvider: (() throws -> Set<RecordID>)? = nil
    ) throws {
        guard let maxImageBytes else { return }
        guard shouldContinue() else { return }
        let context = MacClippyImageRetentionContext(
            store: store,
            blobs: blobs,
            search: search,
            protectedIDs: protectedIDs,
            maxImageBytes: maxImageBytes,
            shouldContinue: shouldContinue,
            withCommitFence: withCommitFence,
            protectedIDsProvider: protectedIDsProvider
        )
        let total = try Self.imageStorageBytes(context)
        guard shouldContinue(), total > maxImageBytes else { return }

        var remaining = total
        var madeProgress = true
        while remaining > maxImageBytes, madeProgress, shouldContinue() {
            madeProgress = false
            try Self.deleteImagePageCandidates(
                context: context,
                remaining: &remaining,
                madeProgress: &madeProgress
            )
        }
    }

    private static func imageStorageBytes(_ context: MacClippyImageRetentionContext) throws -> Int {
        var total = 0
        // Only image records can carry a legacy primary image blob. Avoid
        // decrypting every text/file envelope during the image-cap sweep.
        try scanMetadataPagesOldest(
            store: context.store,
            contentKind: .image,
            shouldContinue: context.shouldContinue
        ) { page in
            for meta in page where !context.protectedIDs.contains(meta.id) {
                let body = try context.store.body(for: meta.id)
                guard let blobID = body.imageBlobID else { continue }
                total += try context.blobs.byteSizeChecked(id: blobID)
            }
            return false
        }
        return total
    }

    private static func deleteImagePageCandidates(
        context: MacClippyImageRetentionContext,
        remaining: inout Int,
        madeProgress: inout Bool
    ) throws {
        try scanMetadataPagesOldest(
            store: context.store,
            contentKind: .image,
            shouldContinue: context.shouldContinue
        ) { page in
            let candidates = page.filter { !context.protectedIDs.contains($0.id) }
            var candidateIndex = 0
            while remaining > context.maxImageBytes, candidateIndex < candidates.count {
                guard let batch = try makeImageDeletionBatch(
                    candidates: candidates,
                    candidateIndex: &candidateIndex,
                    context: context,
                    remaining: remaining,
                    maxImageBytes: context.maxImageBytes
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
                        try revalidatedImageIDs(
                            ids,
                            expected: batch.expectedFootprints,
                            store: context.store,
                            blobs: context.blobs
                        )
                    }
                )
                for id in deletedIDs {
                    remaining -= batch.expectedFootprints[id]?.byteCount ?? 0
                }
                madeProgress = madeProgress || !deletedIDs.isEmpty
            }
            return remaining <= context.maxImageBytes
        }
    }

    private static func makeImageDeletionBatch(
        candidates: [ClipboardItemMeta],
        candidateIndex: inout Int,
        context: MacClippyImageRetentionContext,
        remaining: Int,
        maxImageBytes: Int
    ) throws -> (ids: [RecordID], expectedFootprints: [RecordID: MacClippyExpectedImageFootprint])? {
        var ids: [RecordID] = []
        var expectedFootprints: [RecordID: MacClippyExpectedImageFootprint] = [:]
        var plannedRemaining = remaining
        while candidateIndex < candidates.count, plannedRemaining > maxImageBytes {
            let meta = candidates[candidateIndex]
            candidateIndex += 1
            let body = try context.store.body(for: meta.id)
            guard let blobID = body.imageBlobID else { continue }
            let byteCount = try context.blobs.byteSizeChecked(id: blobID)
            ids.append(meta.id)
            expectedFootprints[meta.id] = MacClippyExpectedImageFootprint(
                modified: meta.modified,
                blobID: blobID,
                byteCount: byteCount
            )
            plannedRemaining -= byteCount
        }
        guard !ids.isEmpty else { return nil }
        return (ids, expectedFootprints)
    }

    private static func revalidatedImageIDs(
        _ ids: [RecordID],
        expected: [RecordID: MacClippyExpectedImageFootprint],
        store: ClipboardStore,
        blobs: BlobStore
    ) throws -> [RecordID] {
        let currentMetas = try store.metas(for: ids)
        var validIDs: [RecordID] = []
        for meta in currentMetas {
            guard let expectedFootprint = expected[meta.id],
                  expectedFootprint.modified == meta.modified else { continue }
            let body = try store.body(for: meta.id)
            guard body.imageBlobID == expectedFootprint.blobID,
                  let currentBlobID = body.imageBlobID,
                  try blobs.byteSizeChecked(id: currentBlobID) == expectedFootprint.byteCount
            else {
                continue
            }
            validIDs.append(meta.id)
        }
        return validIDs
    }
}
