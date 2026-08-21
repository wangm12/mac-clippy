import AppKit
import CoreGraphics
import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    private static let cardPreviewCharacterLimit = 2_000
    private static let detailsOCRCharacterLimit = 16_000

    private static func boundedDisplayText(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let remaining = value.count - limit
        return String(value.prefix(limit))
            + "\n\n— Preview shortened for performance · \(remaining) more characters —"
    }

    func snippets() throws -> [MacClippySnippetEntry] {
        try withStoreLock {
            let snippets = try snippetStore.list()
            snippetLookupSnapshot.replace(with: snippets)
            return snippets.map { MacClippySnippetEntry(snippet: $0) }
        }
    }

    func metadataOnlyHistoryEntry(for meta: ClipboardItemMeta) -> MacClippyHistoryEntry? {
        guard let contentKind = meta.contentKind,
              contentKind == .text || contentKind == .html || contentKind == .rtf else {
            return nil
        }
        return MacClippyHistoryEntry(
            meta: meta,
            contentKind: contentKind,
            preview: String(meta.preview.prefix(Self.cardPreviewCharacterLimit))
        )
    }

    func createSnippet(from recordID: RecordID) throws -> MacClippySnippetEntry {
        try withStoreLock {
            let record = try clipboardStore.body(for: recordID)
            guard let body = MacClippyClipboardText.plainText(from: record) else {
                throw MacClippySnippetCreationError.unsupportedContent
            }

            let name = snippetName(for: body)
            let snippet = try snippetStore.create(name: name, body: body)
            snippetLookupSnapshot.replace(with: try snippetStore.list())
            return MacClippySnippetEntry(snippet: snippet)
        }
    }

    func createSnippet(name: String, trigger: String?, body: String) throws -> MacClippySnippetEntry {
        try withStoreLock {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else {
                throw MacClippySnippetCreationError.invalidName
            }

            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MacClippySnippetCreationError.emptyBody
            }

            let normalizedTrigger = normalizedSnippetTrigger(trigger)
            if let normalizedTrigger, try snippetStore.find(trigger: normalizedTrigger) != nil {
                throw MacClippySnippetCreationError.duplicateTrigger
            }

            let snippet = try snippetStore.create(
                name: normalizedName,
                body: body,
                trigger: normalizedTrigger
            )
            let snippets = try snippetStore.list()
            snippetLookupSnapshot.replace(with: snippets)
            return MacClippySnippetEntry(snippet: snippet)
        }
    }

    private func snippetName(for body: String) -> String {
        let firstLine = body.components(separatedBy: .newlines).first ?? body
        let normalized = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Snippet" }
        return String(normalized.prefix(48))
    }

    private func normalizedSnippetTrigger(_ trigger: String?) -> String? {
        guard let trigger = trigger?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trigger.isEmpty else { return nil }
        return trigger.hasPrefix(";") ? trigger : ";\(trigger)"
    }

    // Thumbnail callers only need the primary image bytes. Keep this separate
    // from the general preview enum so card rendering does not construct or
    // retain text/file preview values on the image path.
    func imageData(id: RecordID) throws -> Data {
        try withStoreLock {
            switch try clipboardStore.body(for: id) {
            case let .image(blobID, _, _), let .encryptedImage(blobID, _, _):
                return try blobStore.read(id: blobID, maxBytes: 128 * 1_024 * 1_024)
            case .text, .html, .rtf, .files:
                throw MacClippyStoreError.invalidStoredRecord
            }
        }
    }

    func details(id: RecordID) throws -> MacClippyItemDetails {
        try withStoreLock {
            guard let meta = try clipboardStore.metas(for: [id]).first else {
                throw MacClippyStoreError.recordNotFound
            }
            let record = try clipboardStore.body(for: id)
            let representations = try clipboardStore.representationMetadata(for: id).map { representation in
                let byteCount: Int
                let isAvailable: Bool
                switch representation.payloadState {
                case .present:
                    byteCount = representation.inlineByteCount
                    isAvailable = true
                case .spilled:
                    guard let blobID = representation.blobID else {
                        throw MacClippyStoreError.invalidStoredRecord
                    }
                    let available = try blobStore.containsChecked(id: blobID)
                    byteCount = available ? (try blobStore.byteSizeChecked(id: blobID)) : 0
                    isAvailable = available
                case .unavailable:
                    byteCount = 0
                    isAvailable = false
                case .oversized:
                    byteCount = 0
                    isAvailable = false
                }
                return MacClippyItemRepresentationDetails(
                    uti: representation.uti,
                    payloadState: representation.payloadState,
                    byteCount: byteCount,
                    isAvailable: isAvailable
                )
            }
            let boardNames = try pinboardStore.list().compactMap { board in
                board.itemIDs.contains(id) ? board.name : nil
            }
            let textContent: String?
            let textContentPreview: String?
            let fileURLs: [URL]
            let imageDimensions: CGSize?
            func boundedText(_ value: String) -> (editable: String?, preview: String) {
                guard value.count <= MacClippyDockPreviewTextPolicy.maxRenderedCharacters else {
                    return (nil, MacClippyDockPreviewTextPolicy.displayText(for: value))
                }
                return (value, value)
            }
            switch record {
            case let .text(value):
                let bounded = boundedText(value)
                textContent = bounded.editable
                textContentPreview = bounded.preview
                fileURLs = []
                imageDimensions = nil
            case let .html(value):
                let bounded = boundedText(value)
                textContent = bounded.editable
                textContentPreview = bounded.preview
                fileURLs = []
                imageDimensions = nil
            case let .rtf(data):
                let value = String(data: data, encoding: .utf8)
                    ?? MacClippyClipboardText.plainText(from: .rtf(data))
                    ?? ""
                let bounded = boundedText(value)
                textContent = bounded.editable
                textContentPreview = bounded.preview
                fileURLs = []
                imageDimensions = nil
            case let .files(urls):
                textContent = nil
                textContentPreview = nil
                fileURLs = urls
                imageDimensions = nil
            case let .image(_, width, height), let .encryptedImage(_, width, height):
                textContent = nil
                textContentPreview = nil
                fileURLs = []
                imageDimensions = CGSize(width: width, height: height)
            }
            return MacClippyItemDetails(
                id: id,
                title: meta.customLabel ?? meta.preview,
                contentKind: record.contentKind,
                sourceAppBundleID: meta.sourceAppBundleID,
                created: meta.created,
                modified: meta.modified,
                frequency: meta.frequency,
                lastAccessed: meta.lastAccessed,
                customLabel: meta.customLabel,
                ocrText: meta.ocrText.map {
                    Self.boundedDisplayText($0, limit: Self.detailsOCRCharacterLimit)
                },
                preview: meta.preview,
                textContent: textContent,
                textContentPreview: textContentPreview,
                fileURLs: fileURLs,
                imageDimensions: imageDimensions,
                pinboardNames: boardNames,
                representations: representations
            )
        }
    }

    @discardableResult
    func edit(id: RecordID, text: String) throws -> ClipboardItemMeta {
        try withStoreLock {
            guard let oldMeta = try clipboardStore.metas(for: [id]).first else {
                throw MacClippyStoreError.recordNotFound
            }
            let oldRecord = try clipboardStore.body(for: id)
            let editedRecord: ClipboardRecord
            switch oldRecord {
            case .text:
                editedRecord = .text(text)
            case .html:
                editedRecord = .html(text)
            case .rtf:
                if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{\\rtf") {
                    editedRecord = .rtf(Data(text.utf8))
                } else {
                    let range = NSRange(location: 0, length: text.utf16.count)
                    let data = try NSAttributedString(string: text).data(
                        from: range,
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                    )
                    editedRecord = .rtf(data)
                }
            case .image, .encryptedImage, .files:
                throw MacClippyStoreError.invalidStoredRecord
            }
            let oldBlobIDs = try clipboardStore.blobIDs(for: id)
            let oldRepresentations = try clipboardStore.representations(for: id)
            let updated = try clipboardStore.update(id: id, with: editedRecord)
            do {
                let indexText = Self.searchableIndexText(
                    for: editedRecord,
                    ocrText: updated.ocrText,
                    label: updated.customLabel,
                    representationUTIs: try clipboardStore.representationUTIs(for: id)
                )
                if indexText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try searchStore.remove(kind: .clipboardItem, id: id)
                } else {
                    try searchStore.upsert(kind: .clipboardItem, id: id, text: indexText)
                }

                // An edited text/HTML/RTF record may replace an oversized
                // representation Blob with an inline payload. Reclaim only
                // the blobs that disappeared from this record and are no
                // longer referenced elsewhere; FTS failure above restores the
                // old envelope before this cleanup can run.
                let newBlobIDs = try clipboardStore.blobIDs(for: id)
                let obsoleteBlobIDs = oldBlobIDs.subtracting(newBlobIDs)
                if !obsoleteBlobIDs.isEmpty {
                    let unreferenced = try clipboardStore.unreferencedBlobIDs(obsoleteBlobIDs)
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
            } catch {
                // Restore both the clipboard row and its old FTS projection.
                // Restoring only the envelope would leave history displaying
                // the old text while search still returns the edited text,
                // and would lose a spilled representation's blob reference.
                var rollbackSucceeded = false
                do {
                    let restoredMeta = try clipboardStore.update(id: id, with: oldRecord, now: oldMeta.modified)
                    try clipboardStore.replaceRepresentations(for: id, with: oldRepresentations)
                    let restoredIndexText = Self.searchableIndexText(
                        for: oldRecord,
                        ocrText: restoredMeta.ocrText,
                        label: restoredMeta.customLabel,
                        representationUTIs: try clipboardStore.representationUTIs(for: id)
                    )
                    if restoredIndexText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try searchStore.remove(kind: .clipboardItem, id: id)
                    } else {
                        try searchStore.upsert(kind: .clipboardItem, id: id, text: restoredIndexText)
                    }
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
                throw error
            }
            return updated
        }
    }

}
