import Foundation

private struct MacClippyReconciliationDiagnosticSample<Element: Hashable> {
    private let limit: Int
    private(set) var values: [Element] = []
    private var seen = Set<Element>()
    private(set) var count = 0

    init(limit: Int) {
        self.limit = limit
    }

    mutating func append(_ value: Element) {
        count += 1
        guard values.count < limit, seen.insert(value).inserted else { return }
        values.append(value)
    }
}

private struct MacClippyReconciliationBlobReferenceScan {
    let referenced: MacClippyReachabilityFilter
    let missing: MacClippyReconciliationDiagnosticSample<String>
}

private struct MacClippyReconciliationBlobCleanupScan {
    let orphan: MacClippyReconciliationDiagnosticSample<String>
    let failed: MacClippyReconciliationDiagnosticSample<String>
}

private struct MacClippyReconciliationFTSScan {
    let orphan: MacClippyReconciliationDiagnosticSample<RecordID>
    let missing: MacClippyReconciliationDiagnosticSample<RecordID>
    let failed: MacClippyReconciliationDiagnosticSample<RecordID>
}

private struct MacClippyReachabilityFilter {
    private static let bitCount = 1 << 22
    private static let hashCount = 4
    private var words = [UInt64](repeating: 0, count: bitCount / 64)

    mutating func insert(_ value: String) {
        for index in indexes(for: value) {
            words[index / 64] |= 1 << UInt64(index % 64)
        }
    }

    func mightContain(_ value: String) -> Bool {
        indexes(for: value).allSatisfy { index in
            words[index / 64] & (1 << UInt64(index % 64)) != 0
        }
    }

    private func indexes(for value: String) -> [Int] {
        var first: UInt64 = 14_695_981_039_346_656_037
        var second: UInt64 = 1_099_511_628_211
        for byte in value.utf8 {
            first ^= UInt64(byte)
            first &*= 1_099_511_628_211
            second ^= UInt64(byte)
            second &*= 1_405_759_539_483
        }
        let modulus = UInt64(Self.bitCount)
        return (0 ..< Self.hashCount).map { offset in
            Int((first &+ UInt64(offset) &* second) % modulus)
        }
    }
}

/// Whether a clipboard row should have an FTS document. Images without OCR
/// or a label are intentionally unindexed; treating them as missing would
/// rebuild search on every launch.
public enum MacClippySearchIndexExpectation {
    public static func requiresIndex(_ meta: ClipboardItemMeta) -> Bool {
        if let ocrText = meta.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ocrText.isEmpty {
            return true
        }
        if let label = meta.customLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return true
        }
        return hasSearchablePreview(meta.preview)
    }

    private static func hasSearchablePreview(_ preview: String) -> Bool {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "(no preview)" || trimmed == "(rich text)" {
            return false
        }
        if trimmed.hasPrefix("(image "), trimmed.hasSuffix(")") {
            return false
        }
        return true
    }
}

// Startup reconciliation for orphan blobs and FTS rows. The capture path
// writes the clipboard database, external blobs, and FTS in separate steps, so
// a crash can leave secondary artifacts behind. This service is deliberately
// conservative: a possible blob reference is treated as live, while corrupt
// primary records fail closed before any cleanup begins.
public enum MacClippyReconciliation {
    private static let pageSize = 256
    private static let diagnosticSampleLimit = 256

    public struct Result: Sendable, Equatable {
        public let orphanBlobIDs: [String]
        public let missingBlobIDs: [String]
        public let orphanFTSRecordIDs: [RecordID]
        public let missingFTSRecordIDs: [RecordID]
        public let failedBlobCleanupIDs: [String]
        public let failedFTSCleanupIDs: [RecordID]
        public let orphanBlobCount: Int
        public let missingBlobCount: Int
        public let orphanFTSRecordCount: Int
        public let missingFTSRecordCount: Int
        public let failedBlobCleanupCount: Int
        public let failedFTSCleanupCount: Int

        public init(
            orphanBlobIDs: [String],
            missingBlobIDs: [String] = [],
            orphanFTSRecordIDs: [RecordID],
            missingFTSRecordIDs: [RecordID] = [],
            failedBlobCleanupIDs: [String] = [],
            failedFTSCleanupIDs: [RecordID] = [],
            orphanBlobCount: Int? = nil,
            missingBlobCount: Int? = nil,
            orphanFTSRecordCount: Int? = nil,
            missingFTSRecordCount: Int? = nil,
            failedBlobCleanupCount: Int? = nil,
            failedFTSCleanupCount: Int? = nil
        ) {
            self.orphanBlobIDs = orphanBlobIDs
            self.missingBlobIDs = missingBlobIDs
            self.orphanFTSRecordIDs = orphanFTSRecordIDs
            self.missingFTSRecordIDs = missingFTSRecordIDs
            self.failedBlobCleanupIDs = failedBlobCleanupIDs
            self.failedFTSCleanupIDs = failedFTSCleanupIDs
            self.orphanBlobCount = orphanBlobCount ?? orphanBlobIDs.count
            self.missingBlobCount = missingBlobCount ?? missingBlobIDs.count
            self.orphanFTSRecordCount = orphanFTSRecordCount ?? orphanFTSRecordIDs.count
            self.missingFTSRecordCount = missingFTSRecordCount ?? missingFTSRecordIDs.count
            self.failedBlobCleanupCount = failedBlobCleanupCount ?? failedBlobCleanupIDs.count
            self.failedFTSCleanupCount = failedFTSCleanupCount ?? failedFTSCleanupIDs.count
        }

        public static let empty = MacClippyReconciliation.Result(
            orphanBlobIDs: [],
            orphanFTSRecordIDs: []
        )

        public var isEmpty: Bool {
            orphanBlobCount == 0 && missingBlobCount == 0
                && orphanFTSRecordCount == 0 && missingFTSRecordCount == 0
        }
    }

    /// Detects reconciliation issues without mutating any secondary store.
    /// Diagnostics retain only a bounded sample; the count fields preserve
    /// whether more work existed without making startup memory O(history).
    public static func detect(
        store: ClipboardStore,
        search: SearchStore,
        blobs: BlobStore,
        shouldContinue: () -> Bool = { true }
    ) throws -> Result {
        try scan(
            store: store,
            search: search,
            blobs: blobs,
            shouldContinue: shouldContinue,
            deleteBlob: nil,
            isBlobStillUnreferenced: nil,
            deleteFTS: nil
        )
    }

    /// Detects and repairs issues while scanning. Cleanup happens as each
    /// orphan is discovered, so a large orphan backlog is never retained in a
    /// single result array. Per-item cleanup failures are sampled and counted;
    /// the remaining candidates are still attempted.
    @discardableResult
    public static func reconcile(
        store: ClipboardStore,
        search: SearchStore,
        blobs: BlobStore,
        shouldContinue: () -> Bool = { true },
        deleteBlob: @escaping (String) throws -> Void = { _ in },
        deleteFTS: ((RecordID) throws -> Void)? = nil,
        isBlobStillUnreferenced: ((String) throws -> Bool)? = nil
    ) throws -> Result {
        try scan(
            store: store,
            search: search,
            blobs: blobs,
            shouldContinue: shouldContinue,
            deleteBlob: deleteBlob,
            isBlobStillUnreferenced: isBlobStillUnreferenced,
            deleteFTS: deleteFTS ?? { id in
                try search.remove(kind: .clipboardItem, id: id)
            }
        )
    }

    private static func scan(
        store: ClipboardStore,
        search: SearchStore,
        blobs: BlobStore,
        shouldContinue: () -> Bool,
        deleteBlob: ((String) throws -> Void)?,
        isBlobStillUnreferenced: ((String) throws -> Bool)?,
        deleteFTS: ((RecordID) throws -> Void)?
    ) throws -> Result {
        try store.validateContentKinds(shouldContinue: shouldContinue)
        try store.validateRepresentations(shouldContinue: shouldContinue)

        // A fixed-size Bloom filter has no false negatives. A false positive
        // only leaves a reclaimable orphan on disk, which is the safe failure
        // mode for private clipboard data. This keeps reachability memory
        // bounded even when the history contains hundreds of thousands of
        // records or representation blobs.
        let references = try scanBlobReferences(
            store: store,
            blobs: blobs,
            shouldContinue: shouldContinue
        )
        let blobCleanup = try scanOrphanBlobs(
            blobs: blobs,
            referenced: references.referenced,
            shouldContinue: shouldContinue,
            deleteBlob: deleteBlob,
            isBlobStillUnreferenced: isBlobStillUnreferenced
        )
        let fts = try scanFTS(
            store: store,
            search: search,
            shouldContinue: shouldContinue,
            deleteFTS: deleteFTS
        )

        return Result(
            orphanBlobIDs: blobCleanup.orphan.values.sorted(),
            missingBlobIDs: references.missing.values.sorted(),
            orphanFTSRecordIDs: fts.orphan.values,
            missingFTSRecordIDs: fts.missing.values,
            failedBlobCleanupIDs: blobCleanup.failed.values.sorted(),
            failedFTSCleanupIDs: fts.failed.values,
            orphanBlobCount: blobCleanup.orphan.count,
            missingBlobCount: references.missing.count,
            orphanFTSRecordCount: fts.orphan.count,
            missingFTSRecordCount: fts.missing.count,
            failedBlobCleanupCount: blobCleanup.failed.count,
            failedFTSCleanupCount: fts.failed.count
        )
    }

    private static func scanBlobReferences(
        store: ClipboardStore,
        blobs: BlobStore,
        shouldContinue: () -> Bool
    ) throws -> MacClippyReconciliationBlobReferenceScan {
        var referenced = MacClippyReachabilityFilter()
        var missing = MacClippyReconciliationDiagnosticSample<String>(limit: diagnosticSampleLimit)
        var cursor: MacClippyClipboardHistoryCursor?
        while true {
            guard shouldContinue() else { throw CancellationError() }
            let page = try store.listOldest(limit: pageSize, after: cursor)
            guard !page.isEmpty else { break }
            for meta in page {
                guard shouldContinue() else { throw CancellationError() }
                let body = try store.body(for: meta.id)
                guard meta.contentKind == nil || body.contentKind == meta.contentKind else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                if let blobID = body.imageBlobID {
                    referenced.insert(blobID)
                    if try !blobs.containsChecked(id: blobID) { missing.append(blobID) }
                }
            }
            guard page.count == pageSize, let last = page.last else { break }
            cursor = MacClippyClipboardHistoryCursor(
                modified: last.modified,
                lamport: last.lamport,
                id: last.id
            )
        }
        try store.forEachRepresentationBlobID(shouldContinue: shouldContinue) { blobID in
            referenced.insert(blobID)
            if try !blobs.containsChecked(id: blobID) { missing.append(blobID) }
        }
        return MacClippyReconciliationBlobReferenceScan(referenced: referenced, missing: missing)
    }

    private static func scanOrphanBlobs(
        blobs: BlobStore,
        referenced: MacClippyReachabilityFilter,
        shouldContinue: () -> Bool,
        deleteBlob: ((String) throws -> Void)?,
        isBlobStillUnreferenced: ((String) throws -> Bool)?
    ) throws -> MacClippyReconciliationBlobCleanupScan {
        var orphan = MacClippyReconciliationDiagnosticSample<String>(limit: diagnosticSampleLimit)
        var failed = MacClippyReconciliationDiagnosticSample<String>(limit: diagnosticSampleLimit)
        try blobs.forEachID(shouldContinue: shouldContinue) { blobID in
            guard !referenced.mightContain(blobID) else { return }
            // The reference scan and the disk enumeration are intentionally
            // separate bounded passes. A capture can publish a new reference
            // between them, so revalidate before reporting or deleting the
            // candidate. The runtime performs one final fenced check inside
            // deleteBlob as well, closing the check/delete race.
            if let isBlobStillUnreferenced,
               try !isBlobStillUnreferenced(blobID) {
                return
            }
            orphan.append(blobID)
            guard let deleteBlob else { return }
            do {
                try deleteBlob(blobID)
            } catch {
                failed.append(blobID)
            }
        }
        return MacClippyReconciliationBlobCleanupScan(orphan: orphan, failed: failed)
    }

    private static func scanFTS(
        store: ClipboardStore,
        search: SearchStore,
        shouldContinue: () -> Bool,
        deleteFTS: ((RecordID) throws -> Void)?
    ) throws -> MacClippyReconciliationFTSScan {
        let orphan = try scanOrphanFTS(
            store: store,
            search: search,
            shouldContinue: shouldContinue,
            deleteFTS: deleteFTS
        )
        let missing = try scanMissingFTS(
            store: store,
            search: search,
            shouldContinue: shouldContinue
        )
        return MacClippyReconciliationFTSScan(orphan: orphan.0, missing: missing, failed: orphan.1)
    }

    private static func scanOrphanFTS(
        store: ClipboardStore,
        search: SearchStore,
        shouldContinue: () -> Bool,
        deleteFTS: ((RecordID) throws -> Void)?
    ) throws -> (
        MacClippyReconciliationDiagnosticSample<RecordID>,
        MacClippyReconciliationDiagnosticSample<RecordID>
    ) {
        var orphan = MacClippyReconciliationDiagnosticSample<RecordID>(limit: diagnosticSampleLimit)
        var failed = MacClippyReconciliationDiagnosticSample<RecordID>(limit: diagnosticSampleLimit)
        var lastRowID: Int64?
        while true {
            guard shouldContinue() else { throw CancellationError() }
            let indexedPage = try search.indexedRecordIDPage(
                kind: .clipboardItem,
                afterRowID: lastRowID,
                limit: pageSize
            )
            guard !indexedPage.isEmpty else { break }
            let indexedIDs = indexedPage.map(\.id)
            let existingIDs = Set(try store.metas(for: indexedIDs).map(\.id))
            var deletedInPage = false
            for id in indexedIDs where !existingIDs.contains(id) {
                orphan.append(id)
                guard let deleteFTS else { continue }
                do {
                    try deleteFTS(id)
                    deletedInPage = true
                } catch {
                    failed.append(id)
                }
            }
            guard indexedPage.count == pageSize, let last = indexedPage.last else { break }
            // If a row was deleted, keep the cursor so the replacement row
            // that shifted into this page is examined. Otherwise advance by
            // stable SQLite rowid; deletions cannot move later rowids behind
            // the cursor.
            if !deletedInPage {
                lastRowID = last.rowID
            }
        }
        return (orphan, failed)
    }

    private static func scanMissingFTS(
        store: ClipboardStore,
        search: SearchStore,
        shouldContinue: () -> Bool
    ) throws -> MacClippyReconciliationDiagnosticSample<RecordID> {
        var missing = MacClippyReconciliationDiagnosticSample<RecordID>(limit: diagnosticSampleLimit)
        var cursor: MacClippyClipboardHistoryCursor?
        while true {
            guard shouldContinue() else { throw CancellationError() }
            let page = try store.listOldest(limit: pageSize, after: cursor)
            guard !page.isEmpty else { break }
            let pageIDs = page.map(\.id)
            let indexedIDs = try search.indexedRecordIDs(kind: .clipboardItem, matching: pageIDs)
            for meta in page where !indexedIDs.contains(meta.id) {
                guard MacClippySearchIndexExpectation.requiresIndex(meta) else { continue }
                missing.append(meta.id)
            }
            guard page.count == pageSize, let last = page.last else { break }
            cursor = MacClippyClipboardHistoryCursor(
                modified: last.modified,
                lamport: last.lamport,
                id: last.id
            )
        }
        return missing
    }
}
