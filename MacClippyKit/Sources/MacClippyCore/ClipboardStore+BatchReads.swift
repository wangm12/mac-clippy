import CryptoKit
import Foundation
import GRDB

extension MacClippyClipboardStore {
    /// Validates the persisted discriminator before any maintenance path uses
    /// it to decide which encrypted envelopes or blobs are reachable. Unknown
    /// values are corruption, not an absent record.
    public func validateContentKinds(
        shouldContinue: () -> Bool = { true }
    ) throws {
        let pageSize = 500
        var lastModified: Int64?
        var lastLamport: Int64?
        var lastID: String?
        while true {
            guard shouldContinue() else { throw CancellationError() }
            let rows = try database.queue.read { connection in
                var sql = "SELECT id, content_kind, modified, lamport FROM clipboard_records"
                var arguments: [Any] = []
                if let lastModified, let lastLamport, let lastID {
                    sql += """
                        WHERE modified > ?
                           OR (modified = ? AND lamport > ?)
                           OR (modified = ? AND lamport = ? AND id > ?)
                    """
                    arguments += [lastModified, lastModified, lastLamport, lastModified, lastLamport, lastID]
                }
                sql += " ORDER BY modified, lamport, id LIMIT ?"
                arguments.append(pageSize)
                guard let statementArguments = StatementArguments(arguments) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return try Row.fetchAll(
                    connection,
                    sql: sql,
                    arguments: statementArguments
                )
            }
            guard !rows.isEmpty else { return }
            for row in rows {
                guard let rawID = row["id"] as String?,
                      RecordID(rawValue: rawID) != nil,
                      let rawContentKind = row["content_kind"] as String?,
                      MacClippyContentKind(rawValue: rawContentKind) != nil else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
            }
            guard rows.count == pageSize, let last = rows.last else { return }
            lastModified = last["modified"]
            lastLamport = last["lamport"]
            lastID = last["id"]
        }
    }

    public func contentKinds(for ids: [RecordID]) throws -> [RecordID: MacClippyContentKind] {
        guard !ids.isEmpty else { return [:] }
        var result: [RecordID: MacClippyContentKind] = [:]
        for batch in Self.idBatches(ids) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let values = try database.queue.read { connection in
                try Row.fetchAll(
                    connection,
                    sql: "SELECT id, content_kind FROM clipboard_records WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(batch.map(\.rawValue))
                ).map { row -> (RecordID, MacClippyContentKind) in
                    guard let rawID = row["id"] as String?,
                          let id = RecordID(rawValue: rawID),
                          let rawContentKind = row["content_kind"] as String?,
                          let contentKind = MacClippyContentKind(rawValue: rawContentKind) else {
                        // An existing row with an invalid discriminator must
                        // fail closed. Treating it as missing could make a
                        // still-referenced image blob look orphaned during
                        // reconciliation and allow destructive cleanup.
                        throw MacClippyStoreError.invalidStoredRecord
                    }
                    return (id, contentKind)
                }
            }
            for (id, contentKind) in values {
                result[id] = contentKind
            }
        }
        return result
    }

    public func metas(for ids: [RecordID]) throws -> [ClipboardItemMeta] {
        guard !ids.isEmpty else { return [] }
        var values: [ClipboardItemMeta] = []
        for batch in Self.idBatches(ids) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let rows = try database.queue.read { connection in
                try Row.fetchAll(connection, sql: """
                    SELECT id, created, modified, device_id, lamport, kind, content_kind, preview, source_app,
                           frequency, last_accessed, custom_label, detected_type, ocr_text
                    FROM clipboard_records WHERE id IN (\(placeholders))
                """, arguments: StatementArguments(batch.map(\.rawValue)))
            }
            values.append(contentsOf: try rows.map(Self.meta))
        }
        let byID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    public func body(for id: RecordID) throws -> ClipboardRecord {
        let data: Data = try database.queue.read { connection in
            guard let row = try Row.fetchOne(connection, sql: "SELECT envelope FROM clipboard_records WHERE id = ?", arguments: [id.rawValue]) else {
                throw MacClippyStoreError.recordNotFound
            }
            guard let value = row["envelope"] as Data? else { throw MacClippyStoreError.invalidStoredRecord }
            return value
        }
        return try JSONDecoder().decode(ClipboardRecord.self, from: MacClippyCipher.open(MacClippyEnvelope(combined: data), with: key))
    }

    // Atomically replaces the editable primary payload and its card metadata.
    // Retained representation rows are deliberately updated in place: only
    // the canonical representation for the edited content kind is changed;
    // every other advertised UTI remains untouched.
    @discardableResult

    public func bodies(for ids: [RecordID]) throws -> [RecordID: ClipboardRecord] {
        guard !ids.isEmpty else { return [:] }
        var envelopes: [(String, Data)] = []
        for batch in Self.idBatches(ids) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let batchEnvelopes: [(String, Data)] = try database.queue.read { connection in
                try Row.fetchAll(
                    connection,
                    sql: "SELECT id, envelope FROM clipboard_records WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(batch.map(\.rawValue))
                ).map { row -> (String, Data) in
                    guard let rawID: String = row["id"],
                          RecordID(rawValue: rawID) != nil,
                          let envelope: Data = row["envelope"] else {
                        throw MacClippyStoreError.invalidStoredRecord
                    }
                    return (rawID, envelope)
                }
            }
            envelopes.append(contentsOf: batchEnvelopes)
        }

        var values: [RecordID: ClipboardRecord] = [:]
        values.reserveCapacity(envelopes.count)
        for (rawID, envelope) in envelopes {
            guard let id = RecordID(rawValue: rawID) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            values[id] = try JSONDecoder().decode(
                ClipboardRecord.self,
                from: MacClippyCipher.open(MacClippyEnvelope(combined: envelope), with: key)
            )
        }
        return values
    }
}
