import Foundation
import GRDB

extension MacClippyClipboardStore {
    /// Inserts a new row, or if `contentHash` already exists, bumps frequency,
    /// `last_accessed`, and `modified` on that row and writes nothing else.
    public func appendOrReuse(
        _ record: ClipboardRecord,
        representations: [MacClippyClipboardRepresentation],
        sourceAppBundleID: String? = nil,
        sourceAppDisplayName: String? = nil,
        detectedTypeJSON: String? = nil,
        contentHash: String,
        spillPayload: ((Data) throws -> String)? = nil,
        deleteSpilledPayload: ((String) -> Void)? = nil,
        now: Date = Date()
    ) throws -> MacClippyCapturePersistResult {
        if let reused = try touchDuplicate(contentHash: contentHash, now: now) {
            return MacClippyCapturePersistResult(meta: reused, reusedExisting: true)
        }
        do {
            let meta = try append(
                record,
                representations: representations,
                sourceAppBundleID: sourceAppBundleID,
                sourceAppDisplayName: sourceAppDisplayName,
                detectedTypeJSON: detectedTypeJSON,
                contentHash: contentHash,
                spillPayload: spillPayload,
                deleteSpilledPayload: deleteSpilledPayload,
                now: now
            )
            return MacClippyCapturePersistResult(meta: meta, reusedExisting: false)
        } catch {
            if let reused = try touchDuplicate(contentHash: contentHash, now: now) {
                return MacClippyCapturePersistResult(meta: reused, reusedExisting: true)
            }
            throw error
        }
    }

    public func touchDuplicate(contentHash: String, now: Date = Date()) throws -> ClipboardItemMeta? {
        let milliseconds = Self.milliseconds(now)
        return try database.queue.write { connection in
            guard let existing = try Row.fetchOne(
                connection,
                sql: """
                    SELECT id, created, modified, device_id, lamport, kind, content_kind, preview, source_app,
                           source_app_name, frequency, last_accessed, custom_label, detected_type, ocr_text, envelope
                    FROM clipboard_records
                    WHERE content_hash = ?
                    """,
                arguments: [contentHash]
            ) else {
                return nil
            }
            let id = existing["id"] as String
            guard let envelope = existing["envelope"] as Data?,
                  RecordID(rawValue: id) != nil,
                  (try? JSONDecoder().decode(
                    ClipboardRecord.self,
                    from: MacClippyCipher.open(MacClippyEnvelope(combined: envelope), with: key)
                  )) != nil else {
                try connection.execute(
                    sql: "UPDATE clipboard_records SET content_hash = NULL WHERE id = ?",
                    arguments: [id]
                )
                return nil
            }
            try connection.execute(
                sql: """
                    UPDATE clipboard_records
                    SET frequency = frequency + 1, last_accessed = ?, modified = ?
                    WHERE id = ?
                    """,
                arguments: [milliseconds, milliseconds, id]
            )
            guard let updated = try Row.fetchOne(
                connection,
                sql: """
                    SELECT id, created, modified, device_id, lamport, kind, content_kind, preview, source_app,
                           source_app_name, frequency, last_accessed, custom_label, detected_type, ocr_text
                    FROM clipboard_records
                    WHERE id = ?
                    """,
                arguments: [id]
            ) else {
                throw MacClippyStoreError.recordNotFound
            }
            return try Self.meta(updated)
        }
    }
}
