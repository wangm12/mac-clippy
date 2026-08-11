import Foundation

public extension MacClippyRetentionPolicy {
    func enforceMaxAge(
        store: ClipboardStore,
        blobs: BlobStore,
        search: SearchStore,
        protectedIDs: Set<RecordID>,
        now: Date = Date(),
        shouldContinue: @escaping () -> Bool = { true },
        withCommitFence: ((() throws -> Void) throws -> Void) = { operation in try operation() },
        protectedIDsProvider: (() throws -> Set<RecordID>)? = nil
    ) throws {
        guard let maxAge else { return }
        guard shouldContinue() else { return }
        let cutoff = now.addingTimeInterval(-maxAge)
        try Self.scanMetadataPagesOldest(store: store, shouldContinue: shouldContinue) { page in
            let ids = page.lazy
                .filter { $0.modified < cutoff && !protectedIDs.contains($0.id) }
                .map(\.id)
            let candidateIDs = Array(ids)
            try Self.deleteRecords(
                candidateIDs,
                store: store,
                blobs: blobs,
                search: search,
                protectedIDsProvider: protectedIDsProvider,
                shouldContinue: shouldContinue,
                withCommitFence: withCommitFence,
                revalidateIDs: { ids in
                    let currentMetas = try store.metas(for: ids)
                    return currentMetas.filter { $0.modified < cutoff }.map(\.id)
                }
            )

            // Metadata is ordered newest first. Once the oldest item in this
            // page is inside the retention window, every remaining page is
            // newer and cannot contain another expired item.
            guard let oldestModified = page.last?.modified else { return true }
            return oldestModified >= cutoff
        }
    }
}
