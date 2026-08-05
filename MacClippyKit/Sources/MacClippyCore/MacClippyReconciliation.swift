import Foundation

// Startup reconciliation for orphan blobs and FTS rows.
//
// P0 capture writes the legacy envelope, the representation side table, the
// BlobStore bytes, and the FTS index in separate steps. A crash or force-quit
// mid-capture can leave:
//   - a blob on disk that no clipboard record references (orphan blob), or
//   - an FTS row whose clipboard record was never persisted (orphan FTS row).
//
// This service runs once at startup, off the main thread, and trims both
// kinds of orphans. It is intentionally conservative: it only deletes blobs
// that are referenced by neither the legacy envelope imageBlobID set nor the
// representation side table, and it only deletes FTS rows whose record_id is
// not present in clipboard_records. It never deletes clipboard records or
// representations; those are user-visible data.
public enum MacClippyReconciliation {
    public struct Result: Sendable, Equatable {
        public let orphanBlobIDs: [String]
        public let missingBlobIDs: [String]
        public let orphanFTSRecordIDs: [RecordID]
        public let failedBlobCleanupIDs: [String]
        public let failedFTSCleanupIDs: [RecordID]

        public init(
            orphanBlobIDs: [String],
            missingBlobIDs: [String] = [],
            orphanFTSRecordIDs: [RecordID],
            failedBlobCleanupIDs: [String] = [],
            failedFTSCleanupIDs: [RecordID] = []
        ) {
            self.orphanBlobIDs = orphanBlobIDs
            self.missingBlobIDs = missingBlobIDs
            self.orphanFTSRecordIDs = orphanFTSRecordIDs
            self.failedBlobCleanupIDs = failedBlobCleanupIDs
            self.failedFTSCleanupIDs = failedFTSCleanupIDs
        }

        public static let empty = MacClippyReconciliation.Result(
            orphanBlobIDs: [],
            missingBlobIDs: [],
            orphanFTSRecordIDs: [],
            failedBlobCleanupIDs: [],
            failedFTSCleanupIDs: []
        )

        public var isEmpty: Bool {
            orphanBlobIDs.isEmpty && missingBlobIDs.isEmpty && orphanFTSRecordIDs.isEmpty
        }
    }

    // Detects orphans without deleting them. Useful for diagnostics and for
    // tests that want to assert the detected set before any deletion happens.
    public static func detect(
        store: ClipboardStore,
        search: SearchStore,
        blobs: BlobStore
    ) throws -> MacClippyReconciliation.Result {
        let referencedByEnvelope = try allLegacyImageBlobIDs(store: store)
        let referencedByRepresentations = try store.allRepresentationBlobIDs()
        let referencedBlobIDs = referencedByEnvelope.union(referencedByRepresentations)

        let onDiskBlobIDs = allOnDiskBlobIDs(blobs: blobs)
        let orphanBlobIDs = onDiskBlobIDs.subtracting(referencedBlobIDs).sorted()
        let missingBlobIDs = referencedBlobIDs.subtracting(onDiskBlobIDs).sorted()

        let indexedRecordIDs = try search.indexedRecordIDs(kind: .clipboardItem)
        let existingRecordIDs = Set(try store.allMetas().map(\.id))
        let orphanFTSRecordIDs = indexedRecordIDs.filter { !existingRecordIDs.contains($0) }

        return MacClippyReconciliation.Result(
            orphanBlobIDs: orphanBlobIDs,
            missingBlobIDs: missingBlobIDs,
            orphanFTSRecordIDs: orphanFTSRecordIDs
        )
    }

    // Detects and then deletes orphans. Returns the detected set so callers
    // can inspect what was cleaned up. Individual cleanup errors are collected
    // so one failed file does not abort the rest of the sweep; callers must
    // treat the returned failure sets as degraded state.
    @discardableResult
    public static func reconcile(
        store: ClipboardStore,
        search: SearchStore,
        blobs: BlobStore,
        deleteBlob: (String) throws -> Void = { id in
            // Default no-op; the runtime injects blobs.delete(id:) so the
            // enum stays free of BlobStore mutation in tests.
            _ = id
        }
    ) throws -> MacClippyReconciliation.Result {
        let detected = try detect(store: store, search: search, blobs: blobs)

        var failedBlobCleanupIDs: [String] = []
        for blobID in detected.orphanBlobIDs {
            do {
                try deleteBlob(blobID)
            } catch {
                failedBlobCleanupIDs.append(blobID)
            }
        }

        var failedFTSCleanupIDs: [RecordID] = []
        for recordID in detected.orphanFTSRecordIDs {
            do {
                try search.remove(kind: .clipboardItem, id: recordID)
            } catch {
                failedFTSCleanupIDs.append(recordID)
            }
        }

        return MacClippyReconciliation.Result(
            orphanBlobIDs: detected.orphanBlobIDs,
            missingBlobIDs: detected.missingBlobIDs,
            orphanFTSRecordIDs: detected.orphanFTSRecordIDs,
            failedBlobCleanupIDs: failedBlobCleanupIDs,
            failedFTSCleanupIDs: failedFTSCleanupIDs
        )
    }

    // Collects every image blobID referenced by the legacy single-payload
    // envelope across all records. P0 keeps the legacy envelope as the primary
    // card payload, so any image record still references its blob through
    // .image(blobID:width:height:).
    private static func allLegacyImageBlobIDs(store: ClipboardStore) throws -> Set<String> {
        var ids = Set<String>()
        // `content_kind` is persisted alongside every envelope. Restrict the
        // decrypt pass to image records; text, HTML, RTF, and file records
        // cannot contain a legacy image blob reference. This keeps startup
        // reconciliation proportional to the image subset instead of the
        // entire history.
        for meta in try store.list(limit: Int.max, contentKind: .image) {
            // Fail closed when an image envelope cannot be decrypted or
            // decoded. Treating the reference as absent could classify a
            // still-needed Blob as orphan and delete user data.
            if let blobID = try store.body(for: meta.id).imageBlobID {
                ids.insert(blobID)
            }
        }
        return ids
    }

    // Lists every blob file currently on disk. BlobStore writes one
    // `<id>.bin` file per blob, so we enumerate the blob root directory and
    // strip the extension. The root is derived from BlobStore.encryptedURL
    // by stripping the empty-id fallback's trailing component; because
    // encryptedURL(id:) returns rootURL itself (not a child) when the id is
    // rejected as unsafe, we must NOT delete the last path component here or
    // we would enumerate the parent of the blob root and find nothing.
    private static func allOnDiskBlobIDs(blobs: BlobStore) -> Set<String> {
        let root = blobs.encryptedURL(id: "0")
        let directory = root.deletingLastPathComponent()
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var ids = Set<String>()
        for url in contents {
            guard url.pathExtension == "bin" else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            guard !id.isEmpty else { continue }
            ids.insert(id)
        }
        return ids
    }
}
