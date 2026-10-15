import Foundation

struct MacClippyTotalStorageAccounting {
    var totalBytes = 0
    var unprotectedBlobReferences: [String: Int] = [:]
    var blobByteCounts: [String: Int] = [:]
    let protectedIDs: Set<RecordID>
    var revision: Int64

    mutating func remove(_ footprint: MacClippyStoredPayloadFootprint) {
        totalBytes = max(0, totalBytes - footprint.inlineBytes)
        for blobID in footprint.blobIDs {
            let owners = max(0, (unprotectedBlobReferences[blobID] ?? 0) - 1)
            unprotectedBlobReferences[blobID] = owners
            if owners == 0 {
                // A protected owner or read lease may still retain the file.
                // This budget counts only payload reachable from unprotected history.
                totalBytes = max(0, totalBytes - (blobByteCounts[blobID] ?? 0))
            }
        }
    }
}

extension MacClippyRetentionPolicy {
    static func totalStorageAccounting(
        store: ClipboardStore,
        blobs: BlobStore,
        protectedIDs: Set<RecordID>,
        protectedIDsProvider: (() throws -> Set<RecordID>)?,
        shouldContinue: @escaping () -> Bool
    ) throws -> MacClippyTotalStorageAccounting? {
        // Writers must not turn an inconsistent scan into a destructive budget.
        // Defer to the next maintenance run if a stable snapshot cannot be obtained.
        for _ in 0..<3 {
            guard shouldContinue() else { return nil }
            let currentProtected = try protectedIDsProvider?() ?? protectedIDs
            let revision = try store.recordsRevision()
            var accounting = MacClippyTotalStorageAccounting(protectedIDs: currentProtected, revision: revision)
            do {
                try scanTotalStorageAccounting(
                    store: store, blobs: blobs, accounting: &accounting, shouldContinue: shouldContinue
                )
            } catch MacClippyStoreError.recordNotFound {
                guard try store.recordsRevision() != revision else { throw MacClippyStoreError.recordNotFound }
                continue
            }
            guard shouldContinue() else { return nil }
            let latestProtected = try protectedIDsProvider?() ?? protectedIDs
            if try store.recordsRevision() == revision, latestProtected == currentProtected {
                return accounting
            }
        }
        return nil
    }

    private static func scanTotalStorageAccounting(
        store: ClipboardStore,
        blobs: BlobStore,
        accounting: inout MacClippyTotalStorageAccounting,
        shouldContinue: @escaping () -> Bool
    ) throws {
        try scanMetadataPagesOldest(store: store, shouldContinue: shouldContinue) { page in
            for meta in page {
                guard shouldContinue() else { return true }
                let footprint = try store.storageFootprint(for: meta.id)
                guard !accounting.protectedIDs.contains(meta.id) else { continue }
                addTotalBytes(footprint.inlineBytes, to: &accounting.totalBytes)
                for blobID in footprint.blobIDs {
                    let owners = accounting.unprotectedBlobReferences[blobID, default: 0]
                    accounting.unprotectedBlobReferences[blobID] = owners + 1
                    guard owners == 0 else { continue }
                    let bytes = try blobs.byteSizeChecked(id: blobID)
                    accounting.blobByteCounts[blobID] = bytes
                    addTotalBytes(bytes, to: &accounting.totalBytes)
                }
            }
            return false
        }
    }

    private static func addTotalBytes(_ bytes: Int, to total: inout Int) {
        let (sum, overflow) = total.addingReportingOverflow(bytes)
        total = overflow ? Int.max : sum
    }
}
