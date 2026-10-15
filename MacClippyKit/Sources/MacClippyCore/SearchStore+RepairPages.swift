import Foundation
import GRDB

extension MacClippySearchStore {
    /// Applies one bounded repair page to the active projection. The existing
    /// index remains searchable between page transactions and normal writers
    /// can interleave between calls.
    @discardableResult
    public func applyRepairPage(
        _ documents: [MacClippySearchDocument]
    ) throws -> MacClippySearchRepairReport {
        guard !documents.isEmpty else {
            return MacClippySearchRepairReport(documentsWritten: 0, skippedEmptyDocuments: 0)
        }
        return try database.queue.write { connection in
            var seen = Set<String>()
            var written = 0
            var skipped = 0
            for document in documents {
                guard document.kind == .clipboardItem else {
                    throw MacClippySearchRepairError.documentKindMismatch
                }
                guard seen.insert(document.id.rawValue).inserted else {
                    throw MacClippySearchRepairError.duplicateDocument
                }
                try Self.remove(kind: document.kind, id: document.id, from: connection)
                let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    skipped += 1
                    continue
                }
                try Self.insert(document, in: connection, text: text)
                written += 1
            }
            try connection.execute(
                sql: "UPDATE macclippy_search_state SET value = value + 1 WHERE key = 'index_revision'"
            )
            return MacClippySearchRepairReport(documentsWritten: written, skippedEmptyDocuments: skipped)
        }
    }

    /// Captures a rowid watermark so repair can reconcile existing rows without
    /// accidentally deleting records concurrently inserted after the scan.
    public func maximumProjectionRowID() throws -> Int64? {
        try database.queue.read { connection in
            try Int64.fetchOne(
                connection,
                sql: """
                    SELECT MAX(rowid) FROM (
                        SELECT rowid FROM macclippy_search_index
                        UNION ALL
                        SELECT rowid FROM macclippy_search_keys
                    )
                    """
            )
        }
    }

    /// Reads a bounded page of structurally inconsistent projection rowids.
    /// A caller advances `afterRowID` through a fixed watermark while deleting
    /// each returned page, so work and write transactions stay bounded.
    public func malformedProjectionRowIDs(
        afterRowID: Int64?,
        throughRowID: Int64,
        limit: Int
    ) throws -> [Int64] {
        guard limit > 0 else { return [] }
        return try database.queue.read { connection in
            var sql = """
                SELECT rowid FROM (
                    SELECT index_rows.rowid AS rowid
                    FROM macclippy_search_index AS index_rows
                    LEFT JOIN macclippy_search_keys AS keys ON keys.rowid = index_rows.rowid
                    WHERE keys.rowid IS NULL
                       OR keys.kind != index_rows.kind
                       OR keys.record_id != index_rows.record_id
                    UNION
                    SELECT keys.rowid AS rowid
                    FROM macclippy_search_keys AS keys
                    LEFT JOIN macclippy_search_index AS index_rows ON index_rows.rowid = keys.rowid
                    WHERE index_rows.rowid IS NULL
                       OR keys.kind != index_rows.kind
                       OR keys.record_id != index_rows.record_id
                       OR keys.kind NOT IN (?, ?, ?)
                       OR keys.record_id IS NULL
                       OR trim(keys.record_id) = ''
                )
                WHERE rowid <= ?
                """
            var arguments: [DatabaseValueConvertible] = [
                RecordKind.clipboardItem.rawValue,
                RecordKind.pinboard.rawValue,
                RecordKind.snippet.rawValue,
                throughRowID
            ]
            if let afterRowID {
                sql += " AND rowid > ?"
                arguments.append(afterRowID)
            }
            sql += " ORDER BY rowid ASC LIMIT ?"
            arguments.append(limit)
            guard let statementArguments = StatementArguments(arguments) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return try Int64.fetchAll(connection, sql: sql, arguments: statementArguments)
        }
    }

    /// Removes paired projection rows in one bounded transaction.
    public func removeProjectionRows(rowIDs: [Int64]) throws {
        guard !rowIDs.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: rowIDs.count).joined(separator: ",")
        try database.queue.write { connection in
            let arguments = StatementArguments(rowIDs)
            try connection.execute(
                sql: "DELETE FROM macclippy_search_index WHERE rowid IN (\(placeholders))",
                arguments: arguments
            )
            try connection.execute(
                sql: "DELETE FROM macclippy_search_keys WHERE rowid IN (\(placeholders))",
                arguments: arguments
            )
            try connection.execute(
                sql: "UPDATE macclippy_search_state SET value = value + 1 WHERE key = 'index_revision'"
            )
        }
    }

    /// Removes a bounded set of clipboard rows that no longer exist in the
    /// source store. Rowids, rather than IDs alone, are used to delete both
    /// sides of the projection even when a damaged key points at a wrong row.
    public func removeIndexedRecords(kind: RecordKind, ids: [RecordID]) throws {
        guard !ids.isEmpty else { return }
        for start in stride(from: 0, to: ids.count, by: Self.sqliteIDBatchSize) {
            let batch = Array(ids[start ..< min(start + Self.sqliteIDBatchSize, ids.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            try database.queue.write { connection in
                let rowIDs = try Int64.fetchAll(
                    connection,
                    sql: "SELECT rowid FROM macclippy_search_keys WHERE kind = ? AND record_id IN (\(placeholders))",
                    arguments: StatementArguments([kind.rawValue] + batch.map(\.rawValue))
                )
                guard !rowIDs.isEmpty else { return }
                let rowPlaceholders = Array(repeating: "?", count: rowIDs.count).joined(separator: ",")
                let rowArguments = StatementArguments(rowIDs)
                try connection.execute(
                    sql: "DELETE FROM macclippy_search_index WHERE rowid IN (\(rowPlaceholders))",
                    arguments: rowArguments
                )
                try connection.execute(
                    sql: "DELETE FROM macclippy_search_keys WHERE rowid IN (\(rowPlaceholders))",
                    arguments: rowArguments
                )
                try connection.execute(
                    sql: "UPDATE macclippy_search_state SET value = value + 1 WHERE key = 'index_revision'"
                )
            }
        }
    }

    public func maximumIndexedRecordRowID(kind: RecordKind) throws -> Int64? {
        try database.queue.read { connection in
            try Int64.fetchOne(
                connection,
                sql: "SELECT MAX(rowid) FROM macclippy_search_keys WHERE kind = ?",
                arguments: [kind.rawValue]
            )
        }
    }

    private static func remove(kind: RecordKind, id: RecordID, from connection: Database) throws {
        guard let rowID = try Int64.fetchOne(
            connection,
            sql: "SELECT rowid FROM macclippy_search_keys WHERE kind = ? AND record_id = ?",
            arguments: [kind.rawValue, id.rawValue]
        ) else { return }
        try connection.execute(
            sql: "DELETE FROM macclippy_search_index WHERE rowid = ?",
            arguments: [rowID]
        )
        try connection.execute(
            sql: "DELETE FROM macclippy_search_keys WHERE rowid = ?",
            arguments: [rowID]
        )
    }

    private static func insert(
        _ document: MacClippySearchDocument,
        in connection: Database,
        text: String
    ) throws {
        try connection.execute(
            sql: "INSERT INTO macclippy_search_index(kind, record_id, content) VALUES (?, ?, ?)",
            arguments: [document.kind.rawValue, document.id.rawValue, text]
        )
        try connection.execute(
            sql: "INSERT INTO macclippy_search_keys(kind, record_id, rowid) VALUES (?, ?, ?)",
            arguments: [document.kind.rawValue, document.id.rawValue, connection.lastInsertedRowID]
        )
    }
}
