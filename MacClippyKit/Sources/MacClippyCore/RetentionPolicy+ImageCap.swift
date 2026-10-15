import Foundation

private struct MacClippyExpectedImageFootprint {
    let modified: Date
    let byteCounts: [String: Int]

    var blobIDs: Set<String> { Set(byteCounts.keys) }
}

private struct MacClippyImageDeletionBatch {
    let ids: [RecordID]
    let expectedFootprints: [RecordID: MacClippyExpectedImageFootprint]
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
        // Authenticate once before trusting the normalized image index. Subsequent
        // pages assert that concurrent writers have not invalidated it.
        do {
            try context.store.authenticateOwnedBlobReferenceIndex(shouldContinue: context.shouldContinue)
        } catch is CancellationError {
            return 0
        }

        var total = 0
        var cursor: String?
        let pageSize = MacClippyBlobReferenceIndexPolicy.pageSize
        while context.shouldContinue() {
            let page = try context.store.verifiedImageBlobIDs(after: cursor, limit: pageSize)
            guard !page.isEmpty else { return total }
            for blobID in page {
                guard context.shouldContinue() else { return total }
                add(try context.blobs.byteSizeChecked(id: blobID), to: &total)
            }
            guard page.count == pageSize, let last = page.last else { return total }
            cursor = last
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
            while remaining > context.maxImageBytes,
                  candidateIndex < candidates.count,
                  context.shouldContinue() {
                guard let batch = try makeImageDeletionBatch(
                    candidates: candidates,
                    candidateIndex: &candidateIndex,
                    context: context,
                    remaining: remaining,
                    maxImageBytes: context.maxImageBytes
                ) else { break }

                let deletedIDs = try commitImageDeletionBatch(
                    batch,
                    context: context,
                    remaining: &remaining
                )
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
    ) throws -> MacClippyImageDeletionBatch? {
        var ids: [RecordID] = []
        var expectedFootprints: [RecordID: MacClippyExpectedImageFootprint] = [:]
        var candidateByteCounts: [String: Int] = [:]
        var plannedReclaimedBytes = 0

        while candidateIndex < candidates.count,
              remaining - min(remaining, plannedReclaimedBytes) > maxImageBytes,
              context.shouldContinue() {
            let meta = candidates[candidateIndex]
            candidateIndex += 1

            let footprint = try context.store.storageFootprint(for: meta.id)
            guard !footprint.blobIDs.isEmpty else { continue }
            var byteCounts: [String: Int] = [:]
            for blobID in footprint.blobIDs {
                byteCounts[blobID] = try context.blobs.byteSizeChecked(id: blobID)
                if let existing = candidateByteCounts[blobID], existing != byteCounts[blobID] {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                candidateByteCounts[blobID] = byteCounts[blobID]
            }
            ids.append(meta.id)
            expectedFootprints[meta.id] = MacClippyExpectedImageFootprint(
                modified: meta.modified,
                byteCounts: byteCounts
            )

            let potentiallyReclaimed = try context.store.unreferencedBlobIDsWithoutBackfill(
                Set(candidateByteCounts.keys),
                excluding: Set(ids),
                shouldContinue: context.shouldContinue
            )
            plannedReclaimedBytes = potentiallyReclaimed.reduce(into: 0) { total, blobID in
                if let byteCount = candidateByteCounts[blobID] { add(byteCount, to: &total) }
            }
        }
        guard !ids.isEmpty else { return nil }
        return MacClippyImageDeletionBatch(ids: ids, expectedFootprints: expectedFootprints)
    }

    private static func commitImageDeletionBatch(
        _ batch: MacClippyImageDeletionBatch,
        context: MacClippyImageRetentionContext,
        remaining: inout Int
    ) throws -> [RecordID] {
        let deletion = try deleteRecords(
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
        let deletedIDs = deletion.recordIDs
        guard !deletedIDs.isEmpty else { return deletedIDs }

        let deletedFootprints = deletedIDs.compactMap { batch.expectedFootprints[$0] }
        let candidateBlobIDs = deletedFootprints.reduce(into: Set<String>()) {
            $0.formUnion($1.blobIDs)
        }
        let expectedByteCounts = deletedFootprints.reduce(into: [String: Int]()) { result, footprint in
            result.merge(footprint.byteCounts) { existing, _ in existing }
        }
        for blobID in deletion.reclaimedBlobIDs.intersection(candidateBlobIDs) {
            guard let byteCount = expectedByteCounts[blobID] else { continue }
            remaining = max(0, remaining - byteCount)
        }
        return deletedIDs
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
            let currentFootprint = try store.storageFootprint(for: meta.id)
            guard currentFootprint.blobIDs == expectedFootprint.blobIDs else { continue }
            var sizesMatch = true
            for (blobID, expectedByteCount) in expectedFootprint.byteCounts {
                guard try blobs.byteSizeChecked(id: blobID) == expectedByteCount else {
                    sizesMatch = false
                    break
                }
            }
            if sizesMatch { validIDs.append(meta.id) }
        }
        return validIDs
    }

    private static func add(_ byteCount: Int, to total: inout Int) {
        let (sum, overflow) = total.addingReportingOverflow(byteCount)
        total = overflow ? Int.max : sum
    }
}
