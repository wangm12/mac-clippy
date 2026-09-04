import AppKit
import CoreGraphics
import Foundation
import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    /// P1 batch delete: delete every supplied clipboard record, remove it from
    /// every pinboard, and reclaim any image blob that is no longer referenced
    /// by another record. The result lists the IDs that were actually deleted
    /// (and were present), the IDs that were not found, and the IDs that were
    /// present but whose per-item delete raised an error (failedIDs). A not-
    /// found ID or a per-item error does NOT abort the batch; the remaining IDs
    /// are still attempted so a single failing item cannot silently make the UI
    /// report a complete success. No-filter semantics are preserved: the
    /// operation acts only on the supplied IDs and never inspects or filters
    /// their content. Only a hard preflight failure (e.g. the DB read to
    /// classify present/missing) throws and aborts the whole batch, since in
    /// that case no per-item outcome is known.
    @discardableResult
    func delete(ids: [RecordID]) throws -> MacClippyBatchDeleteResult {
        try withStoreLock {
            try deleteLocked(ids: ids)
        }
    }

    @discardableResult
    func deleteUnpinnedHistory() throws -> MacClippyBatchDeleteResult {
        try withStoreLock {
            try deleteUnpinnedHistoryLocked()
        }
    }

    @discardableResult
    func deleteUnpinnedHistory(
        for lifecycleToken: MacClippyRuntimeLifecycleToken
    ) throws -> MacClippyBatchDeleteResult {
        guard isCurrentLifecycleToken(lifecycleToken) else {
            throw CancellationError()
        }

        var aggregate = MacClippyBatchDeleteResult(
            deletedIDs: [],
            missingIDs: [],
            failedIDs: []
        )
        let pageSize = 256
        var cursor: MacClippyClipboardHistoryCursor?
        while true {
            guard isCurrentLifecycleToken(lifecycleToken) else {
                throw CancellationError()
            }
            let page = try requireCurrentLifecycleValue(lifecycleToken) {
                try clipboardStore.listOldest(limit: pageSize, after: cursor)
            }
            guard !page.isEmpty else { break }
            cursor = page.last.map {
                MacClippyClipboardHistoryCursor(modified: $0.modified, lamport: $0.lamport, id: $0.id)
            }
            let protectedIDs = try requireCurrentLifecycleValue(lifecycleToken) {
                try PinboardStore.protectedIDs(from: pinboardStore)
            }
            let candidateIDs = page.map(\.id).filter { !protectedIDs.contains($0) }
            if !candidateIDs.isEmpty {
                let pageResult = try requireCurrentLifecycleValue(lifecycleToken) {
                    // Re-read immediately before opening deletion journals so
                    // a pin added while the page was being prepared is not
                    // treated as still unpinned.
                    let currentProtectedIDs = try PinboardStore.protectedIDs(from: pinboardStore)
                    let currentCandidates = candidateIDs.filter { !currentProtectedIDs.contains($0) }
                    return try deleteLocked(ids: currentCandidates, protectedIDs: currentProtectedIDs)
                }
                aggregate = mergeDeleteResults(aggregate, with: pageResult)
            }
            guard page.count == pageSize else { break }
        }
        return aggregate
    }

    private func requireCurrentLifecycleValue<T>(
        _ lifecycleToken: MacClippyRuntimeLifecycleToken,
        _ operation: () throws -> T
    ) throws -> T {
        guard let value = try withCurrentLifecycleStoreLock(lifecycleToken, operation) else {
            throw CancellationError()
        }
        return value
    }

    private func deleteUnpinnedHistoryLocked() throws -> MacClippyBatchDeleteResult {
        let protectedIDs = try PinboardStore.protectedIDs(from: pinboardStore)
        let pageSize = 256
        guard let persistedCount = try clipboardStore.databaseRowCount() else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        let totalCount = Int(persistedCount)
        guard totalCount > 0 else {
            return MacClippyBatchDeleteResult(deletedIDs: [], missingIDs: [], failedIDs: [])
        }

        // Walk from the oldest page backwards. Deleting rows from a later
        // page cannot change the offsets of earlier pages, so this keeps
        // the operation bounded without skipping records as rows shift.
        var offset = ((totalCount - 1) / pageSize) * pageSize
        var aggregate = MacClippyBatchDeleteResult(
            deletedIDs: [],
            missingIDs: [],
            failedIDs: []
        )
        while offset >= 0 {
            let page = try clipboardStore.list(limit: pageSize, offset: offset)
            let candidateIDs = page.map(\.id).filter { !protectedIDs.contains($0) }
            if !candidateIDs.isEmpty {
                aggregate = try mergeDeleteResults(aggregate, with: deleteLocked(ids: candidateIDs))
            }
            offset -= pageSize
        }
        return aggregate
    }

    private func mergeDeleteResults(
        _ first: MacClippyBatchDeleteResult,
        with second: MacClippyBatchDeleteResult
    ) -> MacClippyBatchDeleteResult {
        MacClippyBatchDeleteResult(
            deletedIDs: first.deletedIDs + second.deletedIDs,
            missingIDs: first.missingIDs + second.missingIDs,
            failedIDs: first.failedIDs + second.failedIDs
        )
    }

    private func deleteLocked(
        ids: [RecordID],
        protectedIDs: Set<RecordID>? = nil
    ) throws -> MacClippyBatchDeleteResult {
        let candidates = try classifyDeletionCandidates(ids)
        let boards = try pinboardStore.listStrict()
        let cleanup = beginDeletionCleanup(
            candidateIDs: candidates.candidateIDs,
            protectedIDs: protectedIDs,
            boards: boards
        )
        var failedIDs = cleanup.failedIDs

        guard !cleanup.pending.isEmpty else {
            return MacClippyBatchDeleteResult(
                deletedIDs: [],
                missingIDs: candidates.missingIDs,
                failedIDs: failedIDs
            )
        }

        let blobIDs = cleanup.pending.reduce(into: Set<String>()) { result, pending in
            result.formUnion(pending.journal.blobIDs)
        }
        let unreferenced: Set<String>
        do {
            unreferenced = try clipboardStore.unreferencedBlobIDs(blobIDs)
        } catch {
            failedIDs.append(contentsOf: cleanup.pending.map(\.id))
            return MacClippyBatchDeleteResult(
                deletedIDs: [],
                missingIDs: candidates.missingIDs,
                failedIDs: failedIDs
            )
        }

        let completed = finishDeletionCleanup(
            cleanup.pending,
            unreferenced: unreferenced
        )
        return MacClippyBatchDeleteResult(
            deletedIDs: completed.deletedIDs,
            missingIDs: candidates.missingIDs,
            failedIDs: failedIDs + completed.failedIDs
        )
    }

    private func classifyDeletionCandidates(
        _ ids: [RecordID]
    ) throws -> (candidateIDs: [RecordID], missingIDs: [RecordID]) {
        let presentIDs = Set(try clipboardStore.metas(for: ids).map(\.id))
        var candidateIDs: [RecordID] = []
        var missingIDs: [RecordID] = []
        var seenIDs = Set<RecordID>()

        for id in ids {
            guard seenIDs.insert(id).inserted else { continue }
            if presentIDs.contains(id) {
                candidateIDs.append(id)
            } else {
                missingIDs.append(id)
            }
        }
        return (candidateIDs, missingIDs)
    }

    private func beginDeletionCleanup(
        candidateIDs: [RecordID],
        protectedIDs: Set<RecordID>?,
        boards: [Pinboard]
    ) -> (
        pending: [(id: RecordID, journal: MacClippyDeletionJournalEntry)],
        failedIDs: [RecordID]
    ) {
        var pending: [(id: RecordID, journal: MacClippyDeletionJournalEntry)] = []
        var failedIDs: [RecordID] = []

        for id in candidateIDs {
            guard protectedIDs?.contains(id) != true else { continue }
            do {
                guard let journal = try clipboardStore.beginDeletion(ids: [id]) else {
                    failedIDs.append(id)
                    continue
                }
                try searchStore.remove(kind: .clipboardItem, id: id)
                try clipboardStore.delete(id: id)
                for board in boards where board.itemIDs.contains(id) {
                    try pinboardStore.removeItem(id, from: board.id)
                }
                pending.append((id: id, journal: journal))
            } catch {
                failedIDs.append(id)
            }
        }
        return (pending, failedIDs)
    }

    private func finishDeletionCleanup(
        _ pending: [(id: RecordID, journal: MacClippyDeletionJournalEntry)],
        unreferenced: Set<String>
    ) -> (deletedIDs: [RecordID], failedIDs: [RecordID]) {
        var deletedIDs: [RecordID] = []
        var failedIDs: [RecordID] = []

        for entry in pending {
            do {
                for blobID in entry.journal.blobIDs where unreferenced.contains(blobID) {
                    try blobStore.delete(id: blobID)
                }
                try clipboardStore.completeDeletion(operationID: entry.journal.operationID)
                thumbnailDiskCache.remove(id: entry.id)
                deletedIDs.append(entry.id)
            } catch {
                storageDegradedReasons.insert("orphan-blob-cleanup-failed")
                MacClippyLog.record(
                    category: .blob,
                    code: .blobCleanupFailed,
                    operation: "delete_blob_cleanup",
                    recoveryAction: "run_storage_reconciliation",
                    impact: "deleted_record_cleanup_incomplete"
                )
                failedIDs.append(entry.id)
            }
        }
        return (deletedIDs, failedIDs)
    }

    /// P1 batch pin: add every supplied clipboard record to the target
    /// pinboard, skipping records that are already members and validating both
    /// the board and each record under the existing store lock. The result
    /// lists the IDs that were newly pinned, the IDs that were already members
    /// (safe no-ops), the IDs that were not found, and the IDs that were
    /// present but whose per-item pin raised an error (failedIDs). A not-found
    /// ID or a per-item error does NOT abort the batch; the remaining IDs are
    /// still attempted so a single failing item cannot silently make the UI
    /// report a complete success. No-filter semantics are preserved: the
    /// operation acts only on the supplied IDs and never inspects or filters
    /// their content. Only a hard preflight failure (board fetch or the DB read
    /// to classify present/missing) throws and aborts the whole batch.
    @discardableResult
    func pin(recordIDs: [RecordID], to pinboardID: RecordID) throws -> MacClippyBatchPinResult {
        try withStoreLock {
            let board = try pinboardStore.fetch(id: pinboardID)
            let presentMetas = try clipboardStore.metas(for: recordIDs)
            let presentIDs = Set(presentMetas.map(\.id))

            var pinnedIDs: [RecordID] = []
            var duplicateIDs: [RecordID] = []
            var missingIDs: [RecordID] = []
            var failedIDs: [RecordID] = []
            var seenIDs = Set<RecordID>()

            for id in recordIDs {
                guard seenIDs.insert(id).inserted else { continue }
                if !presentIDs.contains(id) {
                    missingIDs.append(id)
                } else if board.itemIDs.contains(id) {
                    duplicateIDs.append(id)
                } else {
                    // Per-item pin: collect a failure instead of aborting the
                    // whole batch so the UI can report exactly which items
                    // failed and never report a complete success for a partial
                    // batch.
                    do {
                        try pinboardStore.addItem(id, to: pinboardID)
                        pinnedIDs.append(id)
                    } catch {
                        failedIDs.append(id)
                    }
                }
            }

            return MacClippyBatchPinResult(
                boardName: board.name,
                pinnedIDs: pinnedIDs,
                duplicateIDs: duplicateIDs,
                missingIDs: missingIDs,
                failedIDs: failedIDs
            )
        }
    }

}
