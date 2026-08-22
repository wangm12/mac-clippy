import Foundation
import GRDB

public struct MacClippySearchHit: Equatable, Sendable {
    public let kind: RecordKind
    public let id: RecordID
    public let snippet: String
    /// FTS5 rank and rowid form a stable keyset cursor while the index
    /// revision remains unchanged. Rank is intentionally exposed only as
    /// pagination metadata; callers should not display it.
    public let rank: Double
    public let rowID: Int64

    public init(
        kind: RecordKind,
        id: RecordID,
        snippet: String,
        rank: Double = 0,
        rowID: Int64 = 0
    ) {
        self.kind = kind
        self.id = id
        self.snippet = snippet
        self.rank = rank
        self.rowID = rowID
    }
}

public struct MacClippySearchCursor: Equatable, Sendable {
    public let rank: Double
    public let rowID: Int64

    public init(rank: Double, rowID: Int64) {
        self.rank = rank
        self.rowID = rowID
    }
}

public struct MacClippyIndexedRecordID: Equatable, Sendable {
    public let id: RecordID
    public let rowID: Int64

    public init(id: RecordID, rowID: Int64) {
        self.id = id
        self.rowID = rowID
    }
}

public typealias SearchHit = MacClippySearchHit

public final class MacClippySearchStore {
    private static let sqliteIDBatchSize = 500

    public static let migrations: [MacClippyDatabaseMigration] = [
        MacClippyDatabaseMigration(identifier: "001-search-core") { database in
            try database.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS macclippy_search_index USING fts5(
                    kind UNINDEXED, record_id UNINDEXED, content, tokenize = 'porter unicode61'
                );
                CREATE TABLE IF NOT EXISTS macclippy_search_keys(
                    kind TEXT NOT NULL, record_id TEXT NOT NULL, rowid INTEGER NOT NULL,
                    PRIMARY KEY(kind, record_id)
                );
            """)
        },
        MacClippyDatabaseMigration(identifier: "002-search-repair-state") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS macclippy_search_state(
                    key TEXT PRIMARY KEY NOT NULL,
                    value INTEGER NOT NULL
                );
                INSERT OR IGNORE INTO macclippy_search_state(key, value)
                    VALUES ('repair_needed', 0);
            """)
        },
        MacClippyDatabaseMigration(identifier: "003-search-index-revision") { database in
            try database.execute(sql: """
                INSERT OR IGNORE INTO macclippy_search_state(key, value)
                    VALUES ('index_revision', 0);
            """)
        },
        MacClippyDatabaseMigration(identifier: "004-source-projection") { database in
            try database.execute(sql: """
                INSERT OR IGNORE INTO macclippy_search_state(key, value)
                    VALUES ('source_projection_version', 0);
            """)
        }
    ]

    public static let currentSourceProjectionVersion: Int64 = 1

    let database: MacClippyDatabase

    public init(database: MacClippyDatabase) throws {
        self.database = database
        try database.migrate(Self.migrations)
    }

    public func databaseHealth() -> MacClippyDatabaseHealthReport {
        let base = database.healthCheck(requiredTables: [
            "macclippy_search_index",
            "macclippy_search_keys",
            "macclippy_search_state",
            "grdb_migrations"
        ])
        guard base.status == .healthy else { return base }

        do {
            let integrityIssues = try ftsIntegrityIssues()
            guard !integrityIssues.isEmpty else { return base }
            return MacClippyDatabaseHealthReport(
                status: .repairable,
                quickCheckPassed: base.quickCheckPassed,
                foreignKeyViolationCount: base.foreignKeyViolationCount,
                missingTables: base.missingTables,
                issues: base.issues + integrityIssues
            )
        } catch {
            // A failed integrity query is itself a storage failure. Do not
            // report a healthy search database when the consistency check
            // could not run.
            return MacClippyDatabaseHealthReport(
                status: .unrecoverable,
                quickCheckPassed: false,
                foreignKeyViolationCount: base.foreignKeyViolationCount,
                missingTables: base.missingTables,
                issues: base.issues + ["fts-integrity-query-failed"]
            )
        }
    }

    public func databaseRowCount() throws -> Int64? {
        try database.tableRowCount("macclippy_search_keys")
    }

    /// Persists that at least one incremental FTS operation failed. This is
    /// intentionally separate from the FTS rows: the marker survives a
    /// relaunch and can only be cleared after a complete transactional rebuild.
    public func markRepairNeeded() throws {
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE macclippy_search_state SET value = 1 WHERE key = 'repair_needed'"
            )
        }
    }

    public func clearRepairNeeded() throws {
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE macclippy_search_state SET value = 0 WHERE key = 'repair_needed'"
            )
        }
    }

    /// A missing marker is treated as repair-needed. A database that cannot
    /// answer this query is already unhealthy, so the conservative result is
    /// preferable to falsely reporting a complete index.
    public func repairNeeded() throws -> Bool {
        try database.queue.read { connection in
            (try Int.fetchOne(
                connection,
                sql: "SELECT value FROM macclippy_search_state WHERE key = 'repair_needed'"
            ) ?? 1) != 0
        }
    }

    /// Monotonically changes whenever the indexed projection changes. Search
    /// pagination includes this value in its continuation so a later page
    /// cannot silently continue through a different FTS ordering.
    public func indexRevision() throws -> Int64 {
        try database.queue.read { connection in
            try Int64.fetchOne(
                connection,
                sql: "SELECT value FROM macclippy_search_state WHERE key = 'index_revision'"
            ) ?? 0
        }
    }

    public func sourceProjectionVersion() throws -> Int64 {
        try database.queue.read { connection in
            try Int64.fetchOne(
                connection,
                sql: "SELECT value FROM macclippy_search_state WHERE key = 'source_projection_version'"
            ) ?? 0
        }
    }

    public func setSourceProjectionVersion(_ value: Int64) throws {
        try database.queue.write { connection in
            try connection.execute(
                sql: """
                    INSERT INTO macclippy_search_state(key, value)
                    VALUES ('source_projection_version', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [value]
            )
        }
    }

    public func insert(kind: RecordKind = .clipboardItem, id: RecordID, text: String) throws {
        try upsert(kind: kind, id: id, text: text)
    }

    public func upsert(kind: RecordKind = .clipboardItem, id: RecordID, text: String) throws {
        try database.queue.write { connection in
            if let row = try Row.fetchOne(connection, sql: "SELECT rowid FROM macclippy_search_keys WHERE kind = ? AND record_id = ?", arguments: [kind.rawValue, id.rawValue]) {
                let rowID: Int64 = row["rowid"]
                try connection.execute(sql: "DELETE FROM macclippy_search_index WHERE rowid = ?", arguments: [rowID])
                try connection.execute(sql: "DELETE FROM macclippy_search_keys WHERE rowid = ?", arguments: [rowID])
            }
            try connection.execute(sql: "INSERT INTO macclippy_search_index(kind, record_id, content) VALUES (?, ?, ?)", arguments: [kind.rawValue, id.rawValue, text])
            try connection.execute(sql: "INSERT INTO macclippy_search_keys(kind, record_id, rowid) VALUES (?, ?, ?)", arguments: [kind.rawValue, id.rawValue, connection.lastInsertedRowID])
            try connection.execute(
                sql: "UPDATE macclippy_search_state SET value = value + 1 WHERE key = 'index_revision'"
            )
        }
    }

    public func remove(kind: RecordKind = .clipboardItem, id: RecordID) throws {
        try database.queue.write { connection in
            guard let row = try Row.fetchOne(connection, sql: "SELECT rowid FROM macclippy_search_keys WHERE kind = ? AND record_id = ?", arguments: [kind.rawValue, id.rawValue]) else { return }
            let rowID: Int64 = row["rowid"]
            try connection.execute(sql: "DELETE FROM macclippy_search_index WHERE rowid = ?", arguments: [rowID])
            try connection.execute(sql: "DELETE FROM macclippy_search_keys WHERE rowid = ?", arguments: [rowID])
            try connection.execute(
                sql: "UPDATE macclippy_search_state SET value = value + 1 WHERE key = 'index_revision'"
            )
        }
    }

    public func search(
        kind: RecordKind? = .clipboardItem,
        query: String,
        limit: Int,
        offset: Int = 0
    ) throws -> [SearchHit] {
        try search(kind: kind, query: query, limit: limit, offset: offset, after: nil)
    }

    /// Searches after a stable FTS rank/rowid cursor. The caller must keep the
    /// index revision alongside this cursor; if the projection changes, the
    /// cursor is no longer valid and the query must restart.
    public func search(
        kind: RecordKind? = .clipboardItem,
        query: String,
        limit: Int,
        after cursor: MacClippySearchCursor?
    ) throws -> [SearchHit] {
        try search(kind: kind, query: query, limit: limit, offset: 0, after: cursor)
    }

    private func search(
        kind: RecordKind?,
        query: String,
        limit: Int,
        offset: Int,
        after cursor: MacClippySearchCursor?
    ) throws -> [SearchHit] {
        let escaped = Self.ftsQuery(for: query)
        guard !escaped.isEmpty, limit > 0 else { return [] }
        return try database.queue.read { connection in
            var sql = """
                SELECT kind, record_id,
                       snippet(macclippy_search_index, 2, '<', '>', '...', 12) AS snippet,
                       rank AS search_rank,
                       macclippy_search_index.rowid AS search_rowid
                FROM macclippy_search_index
                WHERE macclippy_search_index MATCH ?
            """
            var arguments: [Any] = [escaped]
            if let kind {
                sql += " AND kind = ?"
                arguments.append(kind.rawValue)
            }
            if let cursor {
                sql += " AND (rank > ? OR (rank = ? AND macclippy_search_index.rowid > ?))"
                arguments += [cursor.rank, cursor.rank, cursor.rowID]
            }
            sql += " ORDER BY rank ASC, macclippy_search_index.rowid ASC LIMIT ?"
            arguments.append(limit)
            if cursor == nil {
                sql += " OFFSET ?"
                arguments.append(max(0, offset))
            }
            guard let statementArguments = StatementArguments(arguments) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return try Row.fetchAll(connection, sql: sql, arguments: statementArguments).map { row in
                guard let kind = RecordKind(rawValue: row["kind"]),
                      let id = RecordID(rawValue: row["record_id"]),
                      let rank: Double = row["search_rank"],
                      let rowID: Int64 = row["search_rowid"] else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return SearchHit(kind: kind, id: id, snippet: row["snippet"], rank: rank, rowID: rowID)
            }
        }
    }

    // Returns every record_id currently indexed for the given kind. Used by
    // startup reconciliation to detect FTS rows whose clipboard record has
    // been deleted (orphan FTS rows). Kept narrow so the public API surface
    // does not grow beyond what reconciliation needs.
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
    /// The unpaged overload remains for callers that explicitly need a full
    /// export, while startup cleanup avoids materializing the complete index.
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

    /// Reads the maintenance index in rowid order without OFFSET. A caller
    /// can keep the last rowID and safely continue after deleting rows from
    /// the current page; later rowids do not shift left.
    public func indexedRecordIDPage(
        kind: RecordKind = .clipboardItem,
        afterRowID: Int64? = nil,
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
            sql += " ORDER BY rowid ASC LIMIT ?"
            arguments.append(limit)
            guard let statementArguments = StatementArguments(arguments) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return try Row.fetchAll(
                connection,
                sql: sql,
                arguments: statementArguments
            ).map { row in
                guard let id = RecordID(rawValue: row["record_id"]),
                      let rowID: Int64 = row["rowid"] else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return MacClippyIndexedRecordID(id: id, rowID: rowID)
            }
        }
    }

    /// Returns the indexed subset of a bounded caller-provided ID page. This
    /// keeps reconciliation from materializing every indexed ID in one global
    /// Set while still using batched SQL rather than one query per record.
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
                    sql: "SELECT record_id FROM macclippy_search_keys WHERE kind = ? AND record_id IN (\(placeholders))",
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

    /// Checks both sides of the FTS projection. SQLite's integrity pragmas
    /// validate the database file, but they cannot detect a missing key row,
    /// a dangling key rowid, or a virtual-table row that has no projection
    /// key. Use existence queries rather than materializing the index.
    private func ftsIntegrityIssues() throws -> [String] {
        try database.queue.read { connection in
            var issues: [String] = []
            if try Row.fetchOne(
                connection,
                sql: """
                    SELECT 1
                    FROM macclippy_search_keys AS keys
                    LEFT JOIN macclippy_search_index AS index_rows ON index_rows.rowid = keys.rowid
                    WHERE index_rows.rowid IS NULL
                    LIMIT 1
                """
            ) != nil {
                issues.append("fts-key-dangling-rowid")
            }
            if try Row.fetchOne(
                connection,
                sql: """
                    SELECT 1
                    FROM macclippy_search_index AS index_rows
                    LEFT JOIN macclippy_search_keys AS keys ON keys.rowid = index_rows.rowid
                    WHERE keys.rowid IS NULL
                    LIMIT 1
                """
            ) != nil {
                issues.append("fts-row-without-key")
            }
            if try Row.fetchOne(
                connection,
                sql: """
                    SELECT 1
                    FROM macclippy_search_keys
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
                    SELECT 1
                    FROM macclippy_search_keys AS keys
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

    private static func ftsQuery(for query: String) -> String {
        query.split(whereSeparator: \.isWhitespace)
            .map { token in "\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " ")
    }
}

public typealias SearchStore = MacClippySearchStore
