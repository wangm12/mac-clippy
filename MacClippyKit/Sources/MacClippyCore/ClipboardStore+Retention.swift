import CryptoKit
import Foundation
import GRDB

private struct MacClippyStoredPayloadRow {
    let envelope: Data
    let contentKind: String
    let inlineRepresentationBytes: Int
    let blobIDs: Set<String>
}

private struct MacClippyClipboardUpdatePlan {
    let id: RecordID
    let record: ClipboardRecord
    let milliseconds: Int64
    let contentHash: String?
    let primaryBytes: Data?
    let primaryUTIs: [String]
    let preparedRepresentations: [MacClippyPreparedRepresentation]?
}

extension MacClippyClipboardStore {
    @discardableResult
    public func update(
        id: RecordID,
        with record: ClipboardRecord,
        representations: [MacClippyClipboardRepresentation]? = nil,
        contentHash: String? = nil,
        now: Date = Date()
    ) throws -> ClipboardItemMeta {
        let milliseconds = Self.milliseconds(now)
        let primaryBytes = Self.primaryRepresentationBytes(for: record)
        let primaryUTIs = Self.primaryRepresentationUTIs(for: record)

        if let representations {
            try validateRepresentationLimits(representations)
        }
        let preparedRepresentations = try representations.map { try preparedRepresentationRows(from: $0) }

        try persistUpdate(MacClippyClipboardUpdatePlan(
            id: id,
            record: record,
            milliseconds: milliseconds,
            contentHash: contentHash,
            primaryBytes: primaryBytes,
            primaryUTIs: primaryUTIs,
            preparedRepresentations: preparedRepresentations
        ))

        guard let meta = try metas(for: [id]).first else { throw MacClippyStoreError.recordNotFound }
        return meta
    }

    private func persistUpdate(_ plan: MacClippyClipboardUpdatePlan) throws {
        try database.queue.write { connection in
            try updateRecord(plan, on: connection)
        }
    }

    private func updateRecord(
        _ plan: MacClippyClipboardUpdatePlan,
        on connection: Database
    ) throws {
        let shouldWriteCurrentEnvelope = try needsCurrentEnvelope(
            for: plan.id,
            replacingRepresentations: plan.preparedRepresentations != nil,
            on: connection
        )
        let data = try encodedRecordData(
            plan.record,
            requiresRepresentationRoster: shouldWriteCurrentEnvelope
        )
        let envelope = try MacClippyCipher.seal(data, with: key)
        try connection.execute(sql: """
            UPDATE clipboard_records
            SET modified = ?, content_kind = ?, preview = ?, envelope = ?, content_hash = ?, primary_blob_id = ?
            WHERE id = ?
        """, arguments: [
            plan.milliseconds,
            plan.record.contentKind.rawValue,
            Self.preview(for: plan.record),
            envelope.combined,
            plan.contentHash,
            plan.record.imageBlobID,
            plan.id.rawValue
        ])

        if let prepared = plan.preparedRepresentations {
            try writeRepresentationRows(prepared, for: plan.id, on: connection)
        } else if let bytes = plan.primaryBytes {
            try updatePrimaryRepresentation(
                bytes,
                candidates: plan.primaryUTIs,
                recordID: plan.id,
                on: connection
            )
        }
        if plan.preparedRepresentations != nil || shouldWriteCurrentEnvelope {
            try persistAuthenticatedRepresentationRoster(for: plan.id, on: connection)
            try markAttachmentReferenceIndexVerified(for: plan.id, on: connection)
        }
    }

    private func updatePrimaryRepresentation(
        _ bytes: Data,
        candidates: [String],
        recordID: RecordID,
        on connection: Database
    ) throws {
        for uti in candidates {
            guard let row = try Row.fetchOne(
                connection,
                sql: """
                    SELECT item_index FROM clipboard_representations
                    WHERE record_id = ? AND uti = ?
                    ORDER BY sort_order, item_index LIMIT 1
                    """,
                arguments: [recordID.rawValue, uti]
            ) else { continue }
            let itemIndex: Int = row["item_index"]
            let sealed = try MacClippyCipher.seal(bytes, with: key)
            try connection.execute(sql: """
                UPDATE clipboard_representations
                SET payload = ?, blob_id = NULL, payload_state = 'present'
                WHERE record_id = ? AND item_index = ? AND uti = ?
            """, arguments: [sealed.combined, recordID.rawValue, itemIndex, uti])
            break
        }
    }

    private func needsCurrentEnvelope(
        for id: RecordID,
        replacingRepresentations: Bool,
        on connection: Database
    ) throws -> Bool {
        guard let stored = try Row.fetchOne(
            connection,
            sql: """
                SELECT envelope, content_kind, representation_refs_auth, blob_references_verified
                FROM clipboard_records WHERE id = ?
                """,
            arguments: [id.rawValue]
        ) else {
            throw MacClippyStoreError.recordNotFound
        }
        guard let storedEnvelope: Data = stored["envelope"],
              let storedContentKind: String = stored["content_kind"],
              let storedContentKindValue = MacClippyContentKind(rawValue: storedContentKind),
              let referenceMarker: Int = stored["blob_references_verified"],
              referenceMarker == 0 || referenceMarker == 1 else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        let storedBody = try MacClippyClipboardRecordEnvelopeCodec.decode(
            MacClippyCipher.open(MacClippyEnvelope(combined: storedEnvelope), with: key)
        )
        guard storedBody.record.contentKind == storedContentKindValue else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        let storedRoster: Data? = stored["representation_refs_auth"]
        if let storedRoster {
            try MacClippyRepresentationRosterCodec.validate(
                recordID: id.rawValue,
                envelope: storedRoster,
                on: connection,
                key: key,
                maxRepresentations: inputLimits.maxRepresentationsPerRecord
            )
        } else if storedBody.requiresRepresentationRoster, !replacingRepresentations {
            // A current-format record commits to an authenticated row-set
            // roster. Updating only its body must not turn a missing proof
            // into an apparently legacy record that backfill can trust.
            throw MacClippyStoreError.invalidStoredRecord
        }
        return replacingRepresentations || referenceMarker == 1 || storedRoster != nil
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

        let decodedBody = try MacClippyClipboardRecordEnvelopeCodec.decode(
            MacClippyCipher.open(MacClippyEnvelope(combined: stored.envelope), with: key)
        ).record
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
    public func setCustomLabel(id: RecordID, label: String?) throws -> ClipboardItemMeta {
        try setCustomLabelInternal(id: id, label: label, now: nil)
    }

    @discardableResult
    public func setCustomLabel(id: RecordID, label: String?, now: Date) throws -> ClipboardItemMeta {
        try setCustomLabelInternal(id: id, label: label, now: now)
    }

    private func setCustomLabelInternal(id: RecordID, label: String?, now: Date?) throws -> ClipboardItemMeta {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try database.queue.write { connection in
            if let now {
                let milliseconds = Self.milliseconds(now)
                try connection.execute(
                    sql: "UPDATE clipboard_records SET custom_label = ?, modified = ? WHERE id = ?",
                    arguments: [normalized, milliseconds, id.rawValue]
                )
            } else {
                try connection.execute(
                    sql: "UPDATE clipboard_records SET custom_label = ? WHERE id = ?",
                    arguments: [normalized, id.rawValue]
                )
            }
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
