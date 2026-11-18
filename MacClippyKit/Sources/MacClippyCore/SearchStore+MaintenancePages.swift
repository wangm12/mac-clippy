import Foundation
import GRDB

extension MacClippySearchStore {
    // Returns indexed IDs in rowid order for startup reconciliation.
    public func indexedRecordIDs(kind: RecordKind = .clipboardItem) throws -> [RecordID] {
        try database.queue.read { connection in
            try Row.fetchAll(
                connection,
                sql: "SELECT record_id FROM macclippy_search_keys WHERE kind = ? ORDER BY rowid ASC",
                arguments: [kind.rawValue]
            ).map { row in
                guard let id = RecordID(rawValue: row["record_id"]) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return id
            }
        }
    }

    /// Reads indexed IDs in bounded pages for maintenance and reconciliation.
    public func indexedRecordIDs(
        kind: RecordKind = .clipboardItem,
        limit: Int,
        offset: Int = 0
    ) throws -> [RecordID] {
        guard limit > 0 else { return [] }
        return try database.queue.read { connection in
            try Row.fetchAll(
                connection,
                sql: "SELECT record_id FROM macclippy_search_keys WHERE kind = ? ORDER BY rowid ASC LIMIT ? OFFSET ?",
                arguments: [kind.rawValue, limit, max(0, offset)]
            ).map { row in
                guard let id = RecordID(rawValue: row["record_id"]) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return id
            }
        }
    }

    /// Reads a maintenance page without OFFSET so deletion won't shift later rows.
    public func indexedRecordIDPage(
        kind: RecordKind = .clipboardItem,
        afterRowID: Int64? = nil,
        throughRowID: Int64? = nil,
        limit: Int
    ) throws -> [MacClippyIndexedRecordID] {
        guard limit > 0 else { return [] }
        return try database.queue.read { connection in
            var sql = "SELECT record_id, rowid FROM macclippy_search_keys WHERE kind = ?"
            var arguments: [Any] = [kind.rawValue]
            if let afterRowID {
                sql += " AND rowid > ?"
                arguments.append(afterRowID)
            }
            if let throughRowID {
                sql += " AND rowid <= ?"
                arguments.append(throughRowID)
            }
            sql += " ORDER BY rowid ASC LIMIT ?"
            arguments.append(limit)
            guard let statementArguments = StatementArguments(arguments) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return try Row.fetchAll(connection, sql: sql, arguments: statementArguments).map { row in
                guard let id = RecordID(rawValue: row["record_id"]),
                      let rowID: Int64 = row["rowid"] else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return MacClippyIndexedRecordID(id: id, rowID: rowID)
            }
        }
    }

    /// Returns the indexed subset of a bounded caller-provided ID page.
    public func indexedRecordIDs(
        kind: RecordKind = .clipboardItem,
        matching ids: [RecordID]
    ) throws -> Set<RecordID> {
        guard !ids.isEmpty else { return [] }
        var result = Set<RecordID>()
        for start in stride(from: 0, to: ids.count, by: Self.sqliteIDBatchSize) {
            let batch = Array(ids[start ..< min(start + Self.sqliteIDBatchSize, ids.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let rows = try database.queue.read { connection in
                try Row.fetchAll(
                    connection,
                    sql: """
                        SELECT record_id FROM macclippy_search_keys
                        WHERE kind = ? AND record_id IN (\(placeholders))
                        """,
                    arguments: StatementArguments([kind.rawValue] + batch.map(\.rawValue))
                )
            }
            for row in rows {
                guard let rawID: String = row["record_id"], let id = RecordID(rawValue: rawID) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                result.insert(id)
            }
        }
        return result
    }

    /// Checks both sides of the FTS projection without loading index rows into memory.
    func ftsIntegrityIssues() throws -> [String] {
        try database.withIndependentReadOnlyConnection { connection in
            try ftsIntegrityIssues(on: connection)
        }
    }

    private func ftsIntegrityIssues(on connection: Database) throws -> [String] {
            var issues: [String] = []
            if try Row.fetchOne(
                connection,
                sql: """
                    SELECT 1 FROM macclippy_search_keys AS keys
                    LEFT JOIN macclippy_search_index AS index_rows ON index_rows.rowid = keys.rowid
                    WHERE index_rows.rowid IS NULL LIMIT 1
                    """
            ) != nil {
                issues.append("fts-key-dangling-rowid")
            }
            if try Row.fetchOne(
                connection,
                sql: """
                    SELECT 1 FROM macclippy_search_index AS index_rows
                    LEFT JOIN macclippy_search_keys AS keys ON keys.rowid = index_rows.rowid
                    WHERE keys.rowid IS NULL LIMIT 1
                    """
            ) != nil {
                issues.append("fts-row-without-key")
            }
            if try Row.fetchOne(
                connection,
                sql: """
                    SELECT 1 FROM macclippy_search_keys
                    WHERE kind NOT IN (?, ?, ?) OR record_id IS NULL OR trim(record_id) = ''
                    LIMIT 1
                    """,
                arguments: [
                    RecordKind.clipboardItem.rawValue,
                    RecordKind.pinboard.rawValue,
                    RecordKind.snippet.rawValue
                ]
            ) != nil {
                issues.append("fts-invalid-projection-key")
            }
            if try Row.fetchOne(
                connection,
                sql: """
                    SELECT 1 FROM macclippy_search_keys AS keys
                    JOIN macclippy_search_index AS index_rows ON index_rows.rowid = keys.rowid
                    WHERE keys.kind != index_rows.kind OR keys.record_id != index_rows.record_id
                    LIMIT 1
                    """
            ) != nil {
                issues.append("fts-projection-key-mismatch")
            }
            return issues
    }
}
