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
        now: Date = Date()
    ) throws {
        try enforceItemCap(store: store, blobs: blobs, search: search, protectedIDs: protectedIDs)
        try enforceMaxAge(store: store, blobs: blobs, search: search, protectedIDs: protectedIDs, now: now)
        try enforceImageCap(store: store, blobs: blobs, search: search, protectedIDs: protectedIDs)
        try enforceTotalCap(store: store, blobs: blobs, search: search, protectedIDs: protectedIDs)
    }

    public func enforce(
        store: ClipboardStore,
        blobs: BlobStore,
        search: SearchStore,
        pinboards: PinboardStore,
        now: Date = Date()
    ) throws {
        try enforce(store: store, blobs: blobs, search: search, protectedIDs: PinboardStore.protectedIDs(from: pinboards), now: now)
    }

    public func enforceItemCap(store: ClipboardStore, blobs: BlobStore, search: SearchStore, protectedIDs: Set<RecordID>) throws {
        guard let cap = maxItems else { return }
        let candidates = try store.allMetas().filter { !protectedIDs.contains($0.id) }
        let overflow = max(0, candidates.count - max(0, cap))
        try Self.deleteRecords(candidates.suffix(overflow).map(\.id), store: store, blobs: blobs, search: search)
    }

    public func enforceMaxAge(store: ClipboardStore, blobs: BlobStore, search: SearchStore, protectedIDs: Set<RecordID>, now: Date = Date()) throws {
        guard let maxAge else { return }
        let cutoff = now.addingTimeInterval(-maxAge)
        let ids = try store.allMetas()
            .filter { $0.modified < cutoff && !protectedIDs.contains($0.id) }
            .map(\.id)
        try Self.deleteRecords(ids, store: store, blobs: blobs, search: search)
    }

    public func enforceImageCap(store: ClipboardStore, blobs: BlobStore, search: SearchStore, protectedIDs: Set<RecordID>) throws {
        guard let maxImageBytes else { return }
        var entries: [(meta: ClipboardItemMeta, blobID: String, bytes: Int)] = []
        // Only image records can carry a legacy primary image blob. Avoid
        // decrypting every text/file envelope during the image-cap sweep.
        for meta in try store.list(limit: Int.max, contentKind: .image) where !protectedIDs.contains(meta.id) {
            let body = try store.body(for: meta.id)
            guard let blobID = body.imageBlobID else { continue }
            entries.append((meta, blobID, blobs.byteSize(id: blobID)))
        }
        var total = entries.reduce(0) { $0 + $1.bytes }
        guard total > maxImageBytes else { return }
        var ids: [RecordID] = []
        for entry in entries.sorted(by: { $0.meta.modified < $1.meta.modified }) {
            ids.append(entry.meta.id)
            total -= entry.bytes
            if total <= maxImageBytes { break }
        }
        try Self.deleteRecords(ids, store: store, blobs: blobs, search: search)
    }

    public func enforceTotalCap(store: ClipboardStore, blobs: BlobStore, search: SearchStore, protectedIDs: Set<RecordID>) throws {
        guard let maxTotalBytes else { return }
        var entries: [(meta: ClipboardItemMeta, bytes: Int)] = []
        for meta in try store.allMetas() where !protectedIDs.contains(meta.id) {
            let footprint = try store.storageFootprint(for: meta.id)
            let bytes = footprint.inlineBytes + footprint.blobIDs.reduce(0) { $0 + blobs.byteSize(id: $1) }
            entries.append((meta, bytes))
        }
        var total = entries.reduce(0) { $0 + $1.bytes }
        guard total > maxTotalBytes else { return }
        var ids: [RecordID] = []
        for entry in entries.sorted(by: { $0.meta.modified < $1.meta.modified }) {
            ids.append(entry.meta.id)
            total -= entry.bytes
            if total <= maxTotalBytes { break }
        }
        try Self.deleteRecords(ids, store: store, blobs: blobs, search: search)
    }

    private static func deleteRecords(_ ids: [RecordID], store: ClipboardStore, blobs: BlobStore, search: SearchStore) throws {
        guard !ids.isEmpty else { return }
        guard let journal = try store.beginDeletion(ids: ids) else { return }

        // Keep the journal until every secondary store and blob cleanup step
        // succeeds. If the process is killed at any point, startup can replay
        // the same idempotent operations and retry external blob removal.
        for id in journal.recordIDs {
            try search.remove(kind: .clipboardItem, id: id)
            try store.delete(id: id)
        }

        let referenced = try store.referencedBlobIDs()
        for blobID in journal.blobIDs where !referenced.contains(blobID) {
            try blobs.delete(id: blobID)
        }
        try store.completeDeletion(operationID: journal.operationID)
    }
}

public typealias RetentionPolicy = MacClippyRetentionPolicy
