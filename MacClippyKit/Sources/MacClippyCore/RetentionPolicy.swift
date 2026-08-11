import Foundation

public struct MacClippyRetentionPolicy: Sendable {
    public let maxItems: Int?
    public let maxAge: TimeInterval?
    public let maxImageBytes: Int?
    public let maxTotalBytes: Int?

    public init(
        maxItems: Int? = nil,
        maxAge: TimeInterval? = nil,
        maxAgeSeconds: TimeInterval? = nil,
        maxImageBytes: Int? = nil,
        maxTotalBytes: Int? = nil
    ) {
        self.maxItems = maxItems
        self.maxAge = maxAge ?? maxAgeSeconds
        self.maxImageBytes = maxImageBytes
        self.maxTotalBytes = maxTotalBytes
    }

    public func enforce(
        store: ClipboardStore,
        blobs: BlobStore,
        search: SearchStore,
        protectedIDs: Set<RecordID> = [],
        now: Date = Date(),
        shouldContinue: @escaping () -> Bool = { true },
        withCommitFence: @escaping ((() throws -> Void) throws -> Void) = { operation in
            try operation()
        },
        protectedIDsProvider: (() throws -> Set<RecordID>)? = nil
    ) throws {
        guard shouldContinue() else { return }
        try enforceItemCap(
            store: store,
            blobs: blobs,
            search: search,
            protectedIDs: protectedIDs,
            shouldContinue: shouldContinue,
            withCommitFence: withCommitFence,
            protectedIDsProvider: protectedIDsProvider
        )
        try enforceMaxAge(
            store: store,
            blobs: blobs,
            search: search,
            protectedIDs: protectedIDs,
            now: now,
            shouldContinue: shouldContinue,
            withCommitFence: withCommitFence,
            protectedIDsProvider: protectedIDsProvider
        )
        try enforceImageCap(
            store: store,
            blobs: blobs,
            search: search,
            protectedIDs: protectedIDs,
            shouldContinue: shouldContinue,
            withCommitFence: withCommitFence,
            protectedIDsProvider: protectedIDsProvider
        )
        try enforceTotalCap(
            store: store,
            blobs: blobs,
            search: search,
            protectedIDs: protectedIDs,
            shouldContinue: shouldContinue,
            withCommitFence: withCommitFence,
            protectedIDsProvider: protectedIDsProvider
        )
    }

    public func enforce(
        store: ClipboardStore,
        blobs: BlobStore,
        search: SearchStore,
        pinboards: PinboardStore,
        now: Date = Date(),
        shouldContinue: @escaping () -> Bool = { true }
    ) throws {
        try enforce(
            store: store,
            blobs: blobs,
            search: search,
            protectedIDs: PinboardStore.protectedIDs(from: pinboards),
            now: now,
            shouldContinue: shouldContinue
        )
    }

    public func enforceItemCap(
        store: ClipboardStore,
        blobs: BlobStore,
        search: SearchStore,
        protectedIDs: Set<RecordID>,
        shouldContinue: @escaping () -> Bool = { true },
        withCommitFence: ((() throws -> Void) throws -> Void) = { operation in try operation() },
        protectedIDsProvider: (() throws -> Set<RecordID>)? = nil
    ) throws {
        guard let cap = maxItems else { return }
        guard shouldContinue() else { return }
        let normalizedCap = max(0, cap)
        var unprotectedCount = 0
        try Self.scanMetadataPagesOldest(store: store, shouldContinue: shouldContinue) { page in
            unprotectedCount += page.reduce(into: 0) { count, meta in
                if !protectedIDs.contains(meta.id) { count += 1 }
            }
            return false
        }
        guard shouldContinue(), unprotectedCount > normalizedCap else { return }

        var remaining = unprotectedCount
        var madeProgress = true
        while remaining > normalizedCap, madeProgress, shouldContinue() {
            madeProgress = false
            try Self.scanMetadataPagesOldest(store: store, shouldContinue: shouldContinue) { page in
                let candidates = page.filter { !protectedIDs.contains($0.id) }
                var candidateIndex = 0
                while remaining > normalizedCap, candidateIndex < candidates.count {
                    let needed = remaining - normalizedCap
                    let batch = Array(candidates[candidateIndex...].prefix(needed))
                    candidateIndex += batch.count
                    let ids = batch.map(\.id)
                    let expectedModified = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0.modified) })
                    let deletedIDs = try Self.deleteRecords(
                        ids,
                        store: store,
                        blobs: blobs,
                        search: search,
                        protectedIDsProvider: protectedIDsProvider,
                        shouldContinue: shouldContinue,
                        withCommitFence: withCommitFence,
                        revalidateIDs: { ids in
                            let currentMetas = try store.metas(for: ids)
                            return currentMetas.filter { expectedModified[$0.id] == $0.modified }.map(\.id)
                        }
                    )
                    remaining -= deletedIDs.count
                    madeProgress = madeProgress || !deletedIDs.isEmpty
                }
                return remaining <= normalizedCap
            }
        }
    }
}

public typealias RetentionPolicy = MacClippyRetentionPolicy
