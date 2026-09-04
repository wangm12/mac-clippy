import Foundation

import MacClippyCore

extension MacClippyRuntime {
    func storageHealthLocked() -> [String: MacClippyDatabaseHealthReport] {
        var health = [
            "clipboard": clipboardStore.databaseHealth(),
            "search": searchStore.databaseHealth(),
            "pinboards": pinboardStore.databaseHealth(),
            "snippets": snippetStore.databaseHealth()
        ]
        if storageDegradedReasons.contains("missing-blob-references"),
           let clipboard = health["clipboard"] {
            let issues = Array(Set(clipboard.issues + ["missing-blob-references"])).sorted()
            let status: MacClippyDatabaseHealthStatus = clipboard.status == .unrecoverable
                ? .unrecoverable
                : .degraded
            health["clipboard"] = MacClippyDatabaseHealthReport(
                status: status,
                quickCheckPassed: clipboard.quickCheckPassed,
                foreignKeyViolationCount: clipboard.foreignKeyViolationCount,
                missingTables: clipboard.missingTables,
                issues: issues
            )
        }
        if storageDegradedReasons.contains("storage-reconciliation-failed")
            || storageDegradedReasons.contains("orphan-blob-cleanup-failed") {
            if let clipboard = health["clipboard"] {
                var reconciliationIssues: [String] = []
                if storageDegradedReasons.contains("storage-reconciliation-failed") {
                    reconciliationIssues.append("storage-reconciliation-failed")
                }
                if storageDegradedReasons.contains("orphan-blob-cleanup-failed") {
                    reconciliationIssues.append("orphan-blob-cleanup-failed")
                }
                let issues = Array(Set(clipboard.issues + reconciliationIssues)).sorted()
                health["clipboard"] = MacClippyDatabaseHealthReport(
                    status: clipboard.status == .unrecoverable ? .unrecoverable : .degraded,
                    quickCheckPassed: clipboard.quickCheckPassed,
                    foreignKeyViolationCount: clipboard.foreignKeyViolationCount,
                    missingTables: clipboard.missingTables,
                    issues: issues
                )
            }
        }
        if storageDegradedReasons.contains("orphan-fts-cleanup-failed"),
           let search = health["search"] {
            let issues = Array(Set(search.issues + ["orphan-fts-cleanup-failed"])).sorted()
            health["search"] = MacClippyDatabaseHealthReport(
                status: search.status == .unrecoverable ? .unrecoverable : .degraded,
                quickCheckPassed: search.quickCheckPassed,
                foreignKeyViolationCount: search.foreignKeyViolationCount,
                missingTables: search.missingTables,
                issues: issues
            )
        }
        let ftsRepairNeeded: Bool
        do {
            if storageDegradedReasons.contains("fts-repair-needed") {
                ftsRepairNeeded = true
            } else {
                ftsRepairNeeded = try searchStore.repairNeeded()
            }
        } catch {
            if let search = health["search"] {
                let issues = Array(Set(search.issues + ["search-state-query-failed"])).sorted()
                health["search"] = MacClippyDatabaseHealthReport(
                    status: .unrecoverable,
                    quickCheckPassed: false,
                    foreignKeyViolationCount: search.foreignKeyViolationCount,
                    missingTables: search.missingTables,
                    issues: issues
                )
            }
            return health
        }
        guard ftsRepairNeeded,
              let search = health["search"] else {
            return health
        }
        let issues = Array(Set(search.issues + ["fts-repair-needed"])).sorted()
        let status: MacClippyDatabaseHealthStatus = search.status == .unrecoverable
            ? .unrecoverable
            : .repairable
        health["search"] = MacClippyDatabaseHealthReport(
            status: status,
            quickCheckPassed: search.quickCheckPassed,
            foreignKeyViolationCount: search.foreignKeyViolationCount,
            missingTables: search.missingTables,
            issues: issues
        )
        return health
    }

    func isCorruptStoredRecord(_ error: Error) -> Bool {
        if error is DecodingError {
            return true
        }
        if let storeError = error as? MacClippyStoreError {
            if case .invalidStoredRecord = storeError { return true }
        }
        if let cipherError = error as? MacClippyCipherError {
            switch cipherError {
            case .invalidEnvelope:
                return true
            case .openFailed, .sealFailed:
                return false
            }
        }
        if let blobError = error as? MacClippyBlobError {
            switch blobError {
            case .invalidIdentifier, .missingBlob:
                return true
            case .payloadTooLarge:
                return false
            }
        }
        return false
    }

    func recordCorruptStoredRecord(operation: String) {
        MacClippyLog.record(
            category: .storage,
            code: .corruptStoredRecord,
            operation: operation,
            recoveryAction: "repair_or_delete_corrupt_record",
            impact: "record_skipped"
        )
    }

    func storageUsage() throws -> MacClippyStorageUsage {
        let caps = MacClippyRetentionPreferences.policy()
        return try withStoreLock {
            let itemCount = Int(try clipboardStore.databaseRowCount() ?? 0)
            var imageBytes: Int64 = 0
            var countedBlobIDs = Set<String>()
            for blobID in try clipboardStore.imageBlobIDs() {
                guard countedBlobIDs.insert(blobID).inserted else { continue }
                if let size = try? blobStore.byteSizeChecked(id: blobID) {
                    imageBytes += Int64(size)
                }
            }
            return MacClippyStorageUsage(
                itemCount: itemCount,
                imageBytes: imageBytes,
                totalBytes: MacClippyStorageDashboardPolicy.directoryByteCount(at: paths.blobsURL)
                    + MacClippyStorageDashboardPolicy.directoryByteCount(at: paths.databasesURL),
                maxItems: caps.maxItems ?? MacClippyStorageCapPolicy.defaultMaxItems,
                maxImageBytes: Int64(
                    caps.maxImageBytes
                        ?? MacClippyStorageCapPolicy.defaultMaxImageMegabytes * 1_024 * 1_024
                ),
                maxTotalBytes: Int64(
                    caps.maxTotalBytes
                        ?? MacClippyStorageCapPolicy.defaultMaxHistoryMegabytes * 1_024 * 1_024
                )
            )
        }
    }

    func compressOldImages(now: Date = Date()) throws -> MacClippyImageCompressReport {
        try withStoreLock {
            let protectedIDs = try PinboardStore.protectedIDs(from: pinboardStore)
            var report = MacClippyImageCompressReport()
            var retiredBlobIDs = Set<String>()
            var cursor: MacClippyClipboardHistoryCursor?
            var remaining = 64
            while remaining > 0 {
                let page = try clipboardStore.listOldest(
                    limit: 256,
                    after: cursor,
                    contentKind: .image
                )
                guard !page.isEmpty else { break }
                for meta in page {
                    guard remaining > 0 else { break }
                    guard let result = try compressImageIfEligible(
                        meta,
                        protectedIDs: protectedIDs,
                        now: now
                    ) else { continue }
                    report.compressedCount += 1
                    report.bytesSaved += result.bytesSaved
                    retiredBlobIDs.formUnion(result.retiredBlobIDs)
                    remaining -= 1
                }
                guard remaining > 0, page.count == 256, let last = page.last else { break }
                cursor = MacClippyClipboardHistoryCursor(
                    modified: last.modified,
                    lamport: last.lamport,
                    id: last.id
                )
            }
            for blobID in try clipboardStore.unreferencedBlobIDs(retiredBlobIDs) {
                try blobStore.delete(id: blobID)
            }
            return report
        }
    }

    private func compressImageIfEligible(
        _ meta: ClipboardItemMeta,
        protectedIDs: Set<RecordID>,
        now: Date
    ) throws -> (retiredBlobIDs: Set<String>, bytesSaved: Int64)? {
        let body = try clipboardStore.body(for: meta.id)
        let blobID: String
        let width: Int
        let height: Int
        let rewrite: (String, Int, Int) -> ClipboardRecord
        switch body {
        case let .image(id, storedWidth, storedHeight):
            blobID = id
            width = storedWidth
            height = storedHeight
            rewrite = { ClipboardRecord.image(blobID: $0, width: $1, height: $2) }
        case let .encryptedImage(id, storedWidth, storedHeight):
            blobID = id
            width = storedWidth
            height = storedHeight
            rewrite = { ClipboardRecord.encryptedImage(blobID: $0, width: $1, height: $2) }
        default:
            return nil
        }
        let byteCount = try blobStore.byteSizeChecked(id: blobID)
        guard MacClippyStorageDashboardPolicy.shouldCompress(
            isProtected: protectedIDs.contains(meta.id),
            modified: meta.modified,
            now: now,
            byteCount: byteCount,
            longestEdge: max(width, height)
        ) else {
            return nil
        }
        let original = try blobStore.read(id: blobID, maxBytes: 128 * 1_024 * 1_024)
        guard let compressed = MacClippyThumbnailDownsampler.compressedJPEG(
            from: original,
            maxPixelSize: MacClippyStorageDashboardPolicy.compressTargetMaxPixelSize
        ), MacClippyStorageDashboardPolicy.isWorthReplacing(
            originalBytes: byteCount,
            compressedBytes: compressed.data.count
        ) else {
            return nil
        }
        var retiredBlobIDs = Set<String>([blobID])
        retiredBlobIDs.formUnion(try clipboardStore.representations(for: meta.id).compactMap(\.blobID))
        let newBlobID = try blobStore.write(compressed.data)
        let jpegHash = MacClippyCaptureDedupPolicy.contentHash(
            primary: .image(
                compressed.data,
                width: compressed.width,
                height: compressed.height
            ),
            representations: [
                MacClippyCaptureDedupRepresentation(
                    uti: "public.jpeg",
                    payloadState: MacClippyClipboardRepresentationPayloadState.spilled.rawValue,
                    payloadBytes: nil
                )
            ]
        )
        do {
            _ = try clipboardStore.update(
                id: meta.id,
                with: rewrite(newBlobID, compressed.width, compressed.height),
                representations: [
                    MacClippyClipboardRepresentation(
                        uti: "public.jpeg",
                        payloadBytes: nil,
                        blobID: newBlobID,
                        payloadState: .spilled
                    )
                ],
                contentHash: jpegHash,
                now: meta.modified
            )
        } catch {
            try? blobStore.delete(id: newBlobID)
            throw error
        }
        retiredBlobIDs.remove(newBlobID)
        thumbnailDiskCache.remove(id: meta.id)
        return (retiredBlobIDs, Int64(byteCount - compressed.data.count))
    }
}
