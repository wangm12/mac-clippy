import CryptoKit
import Foundation
import GRDB

private struct MacClippyStoredPayloadRow {
    let envelope: Data
    let contentKind: String
    let inlineRepresentationBytes: Int
    let blobIDs: Set<String>
}

extension MacClippyClipboardStore {
    @discardableResult
    public func update(id: RecordID, with record: ClipboardRecord, now: Date = Date()) throws -> ClipboardItemMeta {
        let envelope = try MacClippyCipher.seal(try JSONEncoder().encode(record), with: key)
        let milliseconds = Self.milliseconds(now)
        let primaryBytes = Self.primaryRepresentationBytes(for: record)
        let primaryUTIs = Self.primaryRepresentationUTIs(for: record)

        try database.queue.write { connection in
            guard try Row.fetchOne(connection, sql: "SELECT id FROM clipboard_records WHERE id = ?", arguments: [id.rawValue]) != nil else {
                throw MacClippyStoreError.recordNotFound
            }
            try connection.execute(sql: """
                UPDATE clipboard_records
                SET modified = ?, content_kind = ?, preview = ?, envelope = ?
                WHERE id = ?
            """, arguments: [
                milliseconds, record.contentKind.rawValue, Self.preview(for: record), envelope.combined, id.rawValue
            ])

            if let primaryBytes,
               let row = try Row.fetchOne(
                   connection,
                   sql: "SELECT uti FROM clipboard_representations WHERE record_id = ? AND uti IN (\(Array(repeating: "?", count: primaryUTIs.count).joined(separator: ","))) ORDER BY sort_order LIMIT 1",
                   arguments: StatementArguments([id.rawValue] + primaryUTIs)
               ) {
                let uti: String = row["uti"]
                let sealed = try MacClippyCipher.seal(primaryBytes, with: key)
                try connection.execute(sql: """
                    UPDATE clipboard_representations
                    SET payload = ?, blob_id = NULL, payload_state = 'present'
                    WHERE record_id = ? AND uti = ?
                """, arguments: [sealed.combined, id.rawValue, uti])
            }
        }

        guard let meta = try metas(for: [id]).first else { throw MacClippyStoreError.recordNotFound }
        return meta
    }

    // Batch body reads for pinboard/history projections. This keeps the SQL
    // work bounded while still avoiding one SELECT per record; decryption still
    // happens once per envelope outside each read transaction.

    public func storageFootprint(for id: RecordID) throws -> MacClippyStoredPayloadFootprint {
        // Retention runs over the entire history. Read the persisted envelope
        // and representation metadata once, then decode the envelope once to
        // discover the legacy primary image Blob. The previous implementation
        // re-encoded the body and called blobIDs(for:), which decoded and read
        // the same record a second time and measured a non-persisted JSON size.
        let stored = try database.queue.read { connection -> MacClippyStoredPayloadRow in
            guard let row = try Row.fetchOne(
                connection,
                sql: "SELECT envelope, content_kind FROM clipboard_records WHERE id = ?",
                arguments: [id.rawValue]
            ) else {
                throw MacClippyStoreError.recordNotFound
            }
            guard let envelope = row["envelope"] as Data?,
                  let rawContentKind = row["content_kind"] as String?,
                  MacClippyContentKind(rawValue: rawContentKind) != nil else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            let representationRows = try Row.fetchAll(
                connection,
                sql: "SELECT payload, blob_id FROM clipboard_representations WHERE record_id = ?",
                arguments: [id.rawValue]
            )
            let inlineRepresentationBytes = representationRows.reduce(into: 0) { total, row in
                total += (row["payload"] as Data?)?.count ?? 0
            }
            let blobIDs = Set(representationRows.compactMap { $0["blob_id"] as String? })
            return MacClippyStoredPayloadRow(
                envelope: envelope,
                contentKind: rawContentKind,
                inlineRepresentationBytes: inlineRepresentationBytes,
                blobIDs: blobIDs
            )
        }

        let decodedBody = try JSONDecoder().decode(
            ClipboardRecord.self,
            from: MacClippyCipher.open(MacClippyEnvelope(combined: stored.envelope), with: key)
        )
        guard decodedBody.contentKind.rawValue == stored.contentKind else {
            // A valid-but-wrong discriminator must never make a referenced
            // image Blob look orphaned during destructive retention work.
            throw MacClippyStoreError.invalidStoredRecord
        }
        var blobIDs = stored.blobIDs
        if decodedBody.contentKind == .image, let primaryBlobID = decodedBody.imageBlobID {
            blobIDs.insert(primaryBlobID)
        }
        return MacClippyStoredPayloadFootprint(
            inlineBytes: stored.envelope.count + stored.inlineRepresentationBytes,
            blobIDs: blobIDs
        )
    }

    public func delete(id: RecordID) throws {
        try database.queue.write { connection in
            try connection.execute(sql: "DELETE FROM clipboard_records WHERE id = ?", arguments: [id.rawValue])
        }
    }

    public func bumpFrequency(id: RecordID, now: Date = Date()) throws {
        try database.queue.write { connection in
            try connection.execute(sql: """
                UPDATE clipboard_records SET frequency = frequency + 1, last_accessed = ? WHERE id = ?
            """, arguments: [Self.milliseconds(now), id.rawValue])
        }
    }

    // P2a: set or clear a trimmed custom label for a clipboard record. A
    // blank/whitespace-only label is normalized to nil so blank input clears
    // the label rather than persisting an empty string. The record's modified
    // timestamp is bumped so the card reflects the edit and ordering by
    // `modified DESC` stays meaningful after a label edit. Returns the updated
    // meta so the runtime can reindex the search store and the dock can
    // refresh the card without an extra read. Throws recordNotFound when the
    // id is not present so the runtime never reindexes a row that was deleted
    // concurrently.
    @discardableResult
    public func setCustomLabel(id: RecordID, label: String?, now: Date = Date()) throws -> ClipboardItemMeta {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let milliseconds = Self.milliseconds(now)
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET custom_label = ?, modified = ? WHERE id = ?",
                arguments: [normalized, milliseconds, id.rawValue]
            )
            // changesCount is the row count touched by the UPDATE that just
            // ran. A zero count means the id was not present; surface
            // recordNotFound so the runtime never reindexes a row that was
            // deleted concurrently.
            guard connection.changesCount > 0 else { throw MacClippyStoreError.recordNotFound }
        }
        guard let meta = (try metas(for: [id])).first else { throw MacClippyStoreError.recordNotFound }
        return meta
    }

    public func setOCRText(id: RecordID, text: String?) throws {
        let boundedText = text.map {
            String(decoding: $0.utf8.prefix(MacClippyCollectionLimits.maxOCRTextUTF8Bytes), as: UTF8.self)
        }
        try database.queue.write { connection in
            try connection.execute(sql: "UPDATE clipboard_records SET ocr_text = ? WHERE id = ?", arguments: [boundedText, id.rawValue])
            guard connection.changesCount > 0 else { throw MacClippyStoreError.recordNotFound }
        }
    }
}
