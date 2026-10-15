import Foundation

import MacClippyCore

private struct MacClippySearchRepairPageResult {
    let documents: [MacClippySearchDocument]?
    let written: Int
    let skipped: Int
    let failed: Int
}

private struct MacClippySearchRepairWalkState {
    var cursor: MacClippyClipboardHistoryCursor?
    var pendingMetas: [ClipboardItemMeta] = []
    var pendingIndex = 0
}

private struct MacClippySearchRepairCounts {
    var written = 0
    var skipped = 0
    var failed = 0

    mutating func add(_ page: MacClippySearchRepairPageResult) {
        written += page.written
        skipped += page.skipped
        failed += page.failed
    }
}

private struct MacClippySearchRepairPageBuilder {
    var documents: [MacClippySearchDocument] = []
    var byteCount = 0
    var failedDocuments = 0
}

extension MacClippyRuntime {
    private static let searchRepairMetadataPageSize = 32
    private static let searchRepairPageByteBudget = 8 * 1024 * 1024

    func repairSearchIndex(shouldCancel: @escaping () -> Bool = { false }) throws -> MacClippySearchRepairReport {
        try repairSearchIndex(lifecycleToken: nil, shouldCancel: shouldCancel)
    }

    func repairSearchIndex(
        for lifecycleToken: MacClippyRuntimeLifecycleToken,
        shouldCancel: @escaping () -> Bool = { false }
    ) throws -> MacClippySearchRepairReport {
        try repairSearchIndex(lifecycleToken: lifecycleToken, shouldCancel: shouldCancel)
    }

    func repairSearchIndexIfNeeded(
        for result: MacClippyReconciliation.Result,
        lifecycleToken: MacClippyRuntimeLifecycleToken
    ) throws -> Bool {
        let searchHealth = searchStore.databaseHealth()
        if try searchStore.sourceProjectionVersion() < SearchStore.currentSourceProjectionVersion {
            try searchStore.markRepairNeeded()
        }
        let repairMarker = try searchStore.repairNeeded()
        let shouldRepair = result.missingFTSRecordCount > 0
            || repairMarker
            || searchHealth.status == .repairable
        guard shouldRepair else { return true }
        do {
            let report = try repairSearchIndex(for: lifecycleToken, shouldCancel: {
                !self.isCurrentLifecycleToken(lifecycleToken)
            })
            return report.failedDocuments == 0
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            storageDegradedReasons.insert("fts-repair-needed")
            return false
        }
    }

    private func repairSearchIndex(
        lifecycleToken: MacClippyRuntimeLifecycleToken?,
        shouldCancel: @escaping () -> Bool
    ) throws -> MacClippySearchRepairReport {
        guard let operation = MacClippyMaintenanceIOCoordinator.shared.beginOperation(
            at: paths.rootURL,
            kind: .searchRepair
        ) else {
            throw CancellationError()
        }
        defer { operation.finish() }
        let shouldStop = {
            shouldCancel() || operation.isCancelled
                || lifecycleToken.map { !self.isCurrentLifecycleToken($0) } == true
        }
        return try runSearchRepair(lifecycleToken: lifecycleToken, shouldStop: shouldStop)
    }
    private func runSearchRepair(
        lifecycleToken: MacClippyRuntimeLifecycleToken?,
        shouldStop: () -> Bool
    ) throws -> MacClippySearchRepairReport {
        let startingState = try beginSearchRepair(
            lifecycleToken: lifecycleToken,
            shouldStop: shouldStop
        )
        let counts = try applySearchRepairPages(
            lifecycleToken: lifecycleToken,
            shouldStop: shouldStop
        )
        try reconcileRepairWatermark(
            startingState.projectionRowID,
            lifecycleToken: lifecycleToken,
            shouldStop: shouldStop
        )

        guard counts.failed == 0 else {
            storageDegradedReasons.insert("fts-repair-needed")
            return searchRepairReport(counts)
        }
        try completeSearchRepair(
            expectedEpoch: startingState.epoch,
            lifecycleToken: lifecycleToken,
            shouldStop: shouldStop
        )
        return searchRepairReport(counts)
    }
    private func applySearchRepairPages(
        lifecycleToken: MacClippyRuntimeLifecycleToken?,
        shouldStop: () -> Bool
    ) throws -> MacClippySearchRepairCounts {
        var walkState = MacClippySearchRepairWalkState()
        var counts = MacClippySearchRepairCounts()
        while true {
            let page = try applyNextSearchRepairPage(
                state: &walkState,
                lifecycleToken: lifecycleToken,
                shouldStop: shouldStop
            )
            guard page.documents != nil else { break }
            counts.add(page)
            #if DEBUG
                MacClippyMaintenanceIOTestHooks.afterSearchRepairPageCommit()
            #endif
            if shouldStop() { throw CancellationError() }
        }
        return counts
    }
    private func searchRepairReport(
        _ counts: MacClippySearchRepairCounts
    ) -> MacClippySearchRepairReport {
        return MacClippySearchRepairReport(
            documentsWritten: counts.written,
            skippedEmptyDocuments: counts.skipped,
            failedDocuments: counts.failed
        )
    }

    private func beginSearchRepair(
        lifecycleToken: MacClippyRuntimeLifecycleToken?,
        shouldStop: () -> Bool
    ) throws -> (epoch: Int64, projectionRowID: Int64?) {
        try withSearchRepairStoreFence(lifecycleToken: lifecycleToken) {
            guard !shouldStop() else { throw CancellationError() }
            try searchStore.markRepairNeeded()
            return (
                epoch: try searchStore.repairEpoch(),
                projectionRowID: try searchStore.maximumProjectionRowID()
            )
        }
    }

    private func applyNextSearchRepairPage(
        state: inout MacClippySearchRepairWalkState,
        lifecycleToken: MacClippyRuntimeLifecycleToken?,
        shouldStop: () -> Bool
    ) throws -> MacClippySearchRepairPageResult {
        try withSearchRepairStoreFence(lifecycleToken: lifecycleToken) {
            guard !shouldStop() else { throw CancellationError() }
            var builder = MacClippySearchRepairPageBuilder()
            while builder.documents.isEmpty {
                guard try loadPendingSearchMetasIfNeeded(&state) else {
                    return MacClippySearchRepairPageResult(
                        documents: nil,
                        written: 0,
                        skipped: 0,
                        failed: 0
                    )
                }
                let currentMetas = try currentPendingSearchMetas(state)
                try appendSearchRepairDocuments(
                    from: currentMetas,
                    state: &state,
                    builder: &builder,
                    shouldStop: shouldStop
                )
            }

            // Materialization and its page write share the short Runtime
            // fence, so a newer edit/delete cannot land between them. The
            // SearchStore transaction itself never calls back into stores.
            #if DEBUG
                MacClippyMaintenanceIOTestHooks.beforeSearchRepairPageCommit()
            #endif
            guard !shouldStop() else { throw CancellationError() }
            let report = try searchStore.applyRepairPage(builder.documents)
            return MacClippySearchRepairPageResult(
                documents: builder.documents,
                written: report.documentsWritten,
                skipped: report.skippedEmptyDocuments,
                failed: builder.failedDocuments
            )
        }
    }

    private func loadPendingSearchMetasIfNeeded(
        _ state: inout MacClippySearchRepairWalkState
    ) throws -> Bool {
        guard state.pendingIndex == state.pendingMetas.count else { return true }
        let metas = try clipboardStore.list(
            limit: Self.searchRepairMetadataPageSize,
            before: state.cursor
        )
        guard !metas.isEmpty else { return false }
        state.pendingMetas = metas
        state.pendingIndex = 0
        if let last = metas.last {
            state.cursor = MacClippyClipboardHistoryCursor(
                modified: last.modified,
                lamport: last.lamport,
                id: last.id
            )
        }
        return true
    }

    private func currentPendingSearchMetas(
        _ state: MacClippySearchRepairWalkState
    ) throws -> [RecordID: ClipboardItemMeta] {
        let ids = state.pendingMetas[state.pendingIndex...].map(\.id)
        return Dictionary(
            uniqueKeysWithValues: try clipboardStore.metas(for: ids).map { ($0.id, $0) }
        )
    }

    private func appendSearchRepairDocuments(
        from currentMetas: [RecordID: ClipboardItemMeta],
        state: inout MacClippySearchRepairWalkState,
        builder: inout MacClippySearchRepairPageBuilder,
        shouldStop: () -> Bool
    ) throws {
        while state.pendingIndex < state.pendingMetas.count {
            if shouldStop() { throw CancellationError() }
            let pendingID = state.pendingMetas[state.pendingIndex].id
            guard let meta = currentMetas[pendingID] else {
                state.pendingIndex += 1
                continue
            }
            let document = try searchRepairDocument(
                for: meta,
                failedDocuments: &builder.failedDocuments,
                shouldCancel: shouldStop
            )
            let documentBytes = document.text.utf8.count
            if !builder.documents.isEmpty,
               builder.byteCount + documentBytes > Self.searchRepairPageByteBudget {
                break
            }
            state.pendingIndex += 1
            builder.documents.append(document)
            builder.byteCount += documentBytes
        }
    }

    private func reconcileRepairWatermark(
        _ watermark: Int64?,
        lifecycleToken: MacClippyRuntimeLifecycleToken?,
        shouldStop: () -> Bool
    ) throws {
        guard let watermark else { return }
        try reconcileStaleSearchRows(
            throughRowID: watermark,
            lifecycleToken: lifecycleToken,
            shouldStop: shouldStop
        )
        try removeMalformedSearchProjectionRows(
            throughRowID: watermark,
            lifecycleToken: lifecycleToken,
            shouldStop: shouldStop
        )
    }

    private func completeSearchRepair(
        expectedEpoch: Int64,
        lifecycleToken: MacClippyRuntimeLifecycleToken?,
        shouldStop: () -> Bool
    ) throws {
        let completed = try withSearchRepairStoreFence(lifecycleToken: lifecycleToken) {
            guard !shouldStop() else { throw CancellationError() }
            let didComplete = try searchStore.completeRepair(
                expectedEpoch: expectedEpoch,
                sourceProjectionVersion: SearchStore.currentSourceProjectionVersion
            )
            if didComplete {
                storageDegradedReasons.remove("fts-repair-needed")
            }
            return didComplete
        }
        guard completed else { throw MacClippySearchRepairError.concurrentProjectionFailure }
    }

    private func reconcileStaleSearchRows(
        throughRowID watermark: Int64,
        lifecycleToken: MacClippyRuntimeLifecycleToken?,
        shouldStop: () -> Bool
    ) throws {
        var lastRowID: Int64?
        while true {
            let page = try withSearchRepairStoreFence(lifecycleToken: lifecycleToken) {
                guard !shouldStop() else { throw CancellationError() }
                let indexedPage = try searchStore.indexedRecordIDPage(
                    kind: .clipboardItem,
                    afterRowID: lastRowID,
                    throughRowID: watermark,
                    limit: Self.searchRepairMetadataPageSize
                )
                guard !indexedPage.isEmpty else { return [] }
                let indexedIDs = indexedPage.map(\.id)
                let existingIDs = Set(try clipboardStore.metas(for: indexedIDs).map(\.id))
                let staleIDs = indexedIDs.filter { !existingIDs.contains($0) }
                try searchStore.removeIndexedRecords(kind: .clipboardItem, ids: staleIDs)
                lastRowID = indexedPage.last?.rowID
                return indexedPage
            }
            guard !page.isEmpty else { return }
            if shouldStop() { throw CancellationError() }
        }
    }

    private func removeMalformedSearchProjectionRows(
        throughRowID watermark: Int64,
        lifecycleToken: MacClippyRuntimeLifecycleToken?,
        shouldStop: () -> Bool
    ) throws {
        var lastRowID: Int64?
        while true {
            let rowIDs = try withSearchRepairStoreFence(lifecycleToken: lifecycleToken) {
                guard !shouldStop() else { throw CancellationError() }
                let rowIDs = try searchStore.malformedProjectionRowIDs(
                    afterRowID: lastRowID,
                    throughRowID: watermark,
                    limit: Self.searchRepairMetadataPageSize
                )
                guard !rowIDs.isEmpty else { return [] }
                try searchStore.removeProjectionRows(rowIDs: rowIDs)
                lastRowID = rowIDs.last
                return rowIDs
            }
            guard !rowIDs.isEmpty else { return }
            if shouldStop() { throw CancellationError() }
        }
    }

    private func withSearchRepairStoreFence<T>(
        lifecycleToken: MacClippyRuntimeLifecycleToken?,
        _ operation: () throws -> T
    ) throws -> T {
        guard let lifecycleToken else { return try withStoreLock(operation) }
        guard let result = try withCurrentLifecycleStoreLock(lifecycleToken, operation) else {
            throw CancellationError()
        }
        return result
    }

    private func searchRepairDocument(
        for meta: ClipboardItemMeta,
        failedDocuments: inout Int,
        shouldCancel: () -> Bool
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
            representationUTIs: try clipboardStore.representationUTIs(for: meta.id),
            sourceAppBundleID: meta.sourceAppBundleID
        )
        return MacClippySearchDocument(id: meta.id, text: text)
    }
}
