import Foundation

import MacClippyCore

extension MacClippyRuntime {
    private static let searchRepairMetadataPageSize = 32
    private static let searchRepairPageByteBudget = 8 * 1024 * 1024

    func repairSearchIndex(shouldCancel: @escaping () -> Bool = { false }) throws -> MacClippySearchRepairReport {
        try withStoreLock {
            try repairSearchIndexLocked(shouldCancel: shouldCancel)
        }
    }

    func repairSearchIndex(
        for lifecycleToken: MacClippyRuntimeLifecycleToken,
        shouldCancel: @escaping () -> Bool = { false }
    ) throws -> MacClippySearchRepairReport {
        guard let report = try withCurrentLifecycleStoreLock(lifecycleToken, {
            try repairSearchIndexLocked(shouldCancel: {
                shouldCancel() || !self.isCurrentLifecycleToken(lifecycleToken)
            })
        }) else {
            throw CancellationError()
        }
        return report
    }

    private func repairSearchIndexLocked(
        shouldCancel: @escaping () -> Bool
    ) throws -> MacClippySearchRepairReport {
        var failedDocuments = 0
        var cursor: MacClippyClipboardHistoryCursor?
        var pendingMetas: [ClipboardItemMeta] = []
        var pendingIndex = 0
        let rebuilt = try searchStore.rebuild(pages: {
            var documents: [MacClippySearchDocument] = []
            var pageBytes = 0

            while documents.isEmpty {
                if pendingIndex == pendingMetas.count {
                    let metas = try clipboardStore.list(
                        limit: Self.searchRepairMetadataPageSize,
                        before: cursor
                    )
                    guard !metas.isEmpty else { return nil }
                    pendingMetas = metas
                    pendingIndex = 0
                    if let last = metas.last {
                        cursor = MacClippyClipboardHistoryCursor(
                            modified: last.modified,
                            lamport: last.lamport,
                            id: last.id
                        )
                    }
                }

                while pendingIndex < pendingMetas.count {
                    if shouldCancel() { throw MacClippySearchRepairError.cancelled }
                    let meta = pendingMetas[pendingIndex]
                    let document = try searchRepairDocument(
                        for: meta,
                        failedDocuments: &failedDocuments,
                        shouldCancel: shouldCancel
                    )
                    let documentBytes = document.text.utf8.count
                    if !documents.isEmpty,
                       pageBytes + documentBytes > Self.searchRepairPageByteBudget {
                        break
                    }
                    pendingIndex += 1
                    documents.append(document)
                    pageBytes += documentBytes
                }
            }

            return documents
        }, shouldCancel: shouldCancel)
        if failedDocuments == 0 {
            try searchStore.clearRepairNeeded()
            storageDegradedReasons.remove("fts-repair-needed")
        } else {
            try searchStore.markRepairNeeded()
            storageDegradedReasons.insert("fts-repair-needed")
        }
        return MacClippySearchRepairReport(
            documentsWritten: rebuilt.documentsWritten,
            skippedEmptyDocuments: rebuilt.skippedEmptyDocuments,
            failedDocuments: failedDocuments
        )
    }

    private func searchRepairDocument(
        for meta: ClipboardItemMeta,
        failedDocuments: inout Int,
        shouldCancel: @escaping () -> Bool
    ) throws -> MacClippySearchDocument {
        if shouldCancel() { throw MacClippySearchRepairError.cancelled }
        let body: ClipboardRecord
        do {
            body = try clipboardStore.body(for: meta.id)
            guard meta.contentKind == nil || meta.contentKind == body.contentKind else {
                throw MacClippyStoreError.invalidStoredRecord
            }
        } catch {
            if isCorruptStoredRecord(error) {
                recordCorruptStoredRecord(operation: "fts_rebuild_record")
                failedDocuments += 1
                return MacClippySearchDocument(id: meta.id, text: "")
            }
            throw error
        }
        let text = Self.searchableIndexText(
            for: body,
            ocrText: meta.ocrText,
            label: meta.customLabel,
            representationUTIs: try clipboardStore.representationUTIs(for: meta.id)
        )
        return MacClippySearchDocument(id: meta.id, text: text)
    }

    func storageHealth() -> [String: MacClippyDatabaseHealthReport] {
        withStoreLock {
            storageHealthLocked()
        }
    }

    func diagnosticsStorageSnapshot() throws -> MacClippyDiagnosticsStorageSnapshot {
        withStoreLock {
            let health = storageHealthLocked()
            var rowCounts: [String: Int64] = [:]
            var rowCountIssues: [String: String] = [:]

            func captureRowCount(_ name: String, _ query: () throws -> Int64?) {
                do {
                    guard let count = try query() else {
                        rowCountIssues[name] = "row-count-unavailable"
                        return
                    }
                    rowCounts[name] = count
                } catch {
                    // Diagnostics must identify an infrastructure failure as
                    // degraded storage instead of turning it into an empty
                    // database by using a zero fallback. Keep the code
                    // redacted; the underlying error may contain a path.
                    rowCountIssues[name] = "row-count-query-failed"
                }
            }

            captureRowCount("clipboard") { try clipboardStore.databaseRowCount() }
            captureRowCount("search") { try searchStore.databaseRowCount() }
            captureRowCount("pinboards") { try pinboardStore.databaseRowCount() }
            captureRowCount("snippets") { try snippetStore.databaseRowCount() }

            return MacClippyDiagnosticsStorageSnapshot(
                databaseHealth: health,
                databaseRowCounts: rowCounts,
                databaseRowCountIssues: rowCountIssues
            )
        }
    }
}
