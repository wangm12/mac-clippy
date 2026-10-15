import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    @discardableResult
    func edit(id: RecordID, text: String) throws -> ClipboardItemMeta {
        try clipboardStore.authenticateOwnedBlobReferenceIndex()
        return try withStoreLock {
            try editRecordWhileStoreLocked(id: id, text: text)
        }
    }

    private func editRecordWhileStoreLocked(id: RecordID, text: String) throws -> ClipboardItemMeta {
        guard let oldMeta = try clipboardStore.metas(for: [id]).first else {
            throw MacClippyStoreError.recordNotFound
        }
        let oldSnapshot = try clipboardStore.playbackSnapshot(for: id)
        let oldRecord = oldSnapshot.record
        let editedRecord = try editedClipboardRecord(from: oldRecord, text: text)
        let oldBlobIDs = try clipboardStore.blobIDs(for: id)
        let editedRepresentations = editedRepresentations(
            from: oldSnapshot.representations,
            replacing: editedRecord
        )
        let updated = try clipboardStore.update(
            id: id,
            with: editedRecord,
            representations: editedRepresentations
        )

        do {
            try updateEditedRecordSearchProjection(id: id, record: editedRecord, meta: updated)
            let newBlobIDs = try clipboardStore.blobIDs(for: id)
            try cleanupObsoleteBlobs(oldBlobIDs.subtracting(newBlobIDs))
        } catch {
            restoreEditedRecordAfterFailure(
                id: id,
                oldMeta: oldMeta,
                oldRecord: oldRecord,
                oldRepresentations: oldSnapshot.representations
            )
            throw error
        }
        return updated
    }

    private func editedRepresentations(
        from representations: [MacClippyClipboardRepresentation],
        replacing record: ClipboardRecord
    ) -> [MacClippyClipboardRepresentation] {
        let uti: String
        let bytes: Data
        switch record {
        case let .text(value):
            uti = NSPasteboard.PasteboardType.string.rawValue
            bytes = Data(value.utf8)
        case let .html(value):
            uti = NSPasteboard.PasteboardType.html.rawValue
            bytes = Data(value.utf8)
        case let .rtf(data):
            uti = NSPasteboard.PasteboardType.rtf.rawValue
            bytes = data
        case .image, .encryptedImage, .files:
            return representations
        }
        let itemIndex = representations.first(where: { $0.uti == uti })?.itemIndex ?? 0
        var edited = representations.filter { $0.itemIndex != itemIndex || $0.uti == uti }
        let replacement = MacClippyClipboardRepresentation(
            itemIndex: itemIndex,
            uti: uti,
            payloadBytes: bytes
        )
        if let position = edited.firstIndex(where: { $0.itemIndex == itemIndex && $0.uti == uti }) {
            edited[position] = replacement
        } else {
            edited.append(replacement)
        }
        return edited
    }

    private func editedClipboardRecord(from oldRecord: ClipboardRecord, text: String) throws -> ClipboardRecord {
        switch oldRecord {
        case .text:
            return .text(text)
        case .html:
            return .html(text)
        case .rtf:
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{\\rtf") {
                return .rtf(Data(text.utf8))
            }
            let range = NSRange(location: 0, length: text.utf16.count)
            let data = try NSAttributedString(string: text).data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            return .rtf(data)
        case .image, .encryptedImage, .files:
            throw MacClippyStoreError.invalidStoredRecord
        }
    }

    private func updateEditedRecordSearchProjection(
        id: RecordID,
        record: ClipboardRecord,
        meta: ClipboardItemMeta
    ) throws {
        let indexText = Self.searchableIndexText(
            for: record,
            ocrText: meta.ocrText,
            label: meta.customLabel,
            representationUTIs: try clipboardStore.representationUTIs(for: id),
            sourceAppBundleID: meta.sourceAppBundleID
        )
        if indexText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try searchStore.remove(kind: .clipboardItem, id: id)
        } else {
            try searchStore.upsert(kind: .clipboardItem, id: id, text: indexText)
        }
    }

    private func restoreEditedRecordAfterFailure(
        id: RecordID,
        oldMeta: ClipboardItemMeta,
        oldRecord: ClipboardRecord,
        oldRepresentations: [MacClippyClipboardRepresentation]
    ) {
        var rollbackSucceeded = false
        do {
            let restoredMeta = try clipboardStore.update(
                id: id,
                with: oldRecord,
                representations: oldRepresentations,
                now: oldMeta.modified
            )
            try updateEditedRecordSearchProjection(id: id, record: oldRecord, meta: restoredMeta)
            rollbackSucceeded = true
        } catch {
            storageDegradedReasons.insert("edit-rollback-failed")
            MacClippyLog.record(
                category: .storage,
                code: .recoveryFailed,
                operation: "edit_record_rollback",
                recoveryAction: "restore_backup_or_repair_storage",
                impact: "edited_record_rollback_incomplete"
            )
        }
        if !rollbackSucceeded {
            markSearchRepairNeededLocked()
        }
        MacClippyLog.record(
            category: .fts,
            code: .ftsIndexFailed,
            operation: "edit_fts_update",
            recoveryAction: rollbackSucceeded ? "none" : "repair_search_index",
            impact: rollbackSucceeded
                ? "edit_reverted_after_search_failure"
                : "edited_record_search_state_needs_repair"
        )
    }

    private func cleanupObsoleteBlobs(_ blobIDs: Set<String>) throws {
        guard !blobIDs.isEmpty else { return }
        let unreferenced = try clipboardStore.unreferencedBlobIDs(blobIDs)
        for blobID in unreferenced {
            do {
                try blobStore.delete(id: blobID)
            } catch {
                storageDegradedReasons.insert("orphan-blob-cleanup-failed")
                MacClippyLog.record(
                    category: .blob,
                    code: .blobCleanupFailed,
                    operation: "edit_obsolete_blob_cleanup",
                    recoveryAction: "run_storage_reconciliation",
                    impact: "edited_record_saved_but_blob_cleanup_incomplete"
                )
            }
        }
    }
}
