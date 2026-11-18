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
    static let sqliteIDBatchSize = 500

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
        },
        MacClippySearchStore.maintenanceIndexMigration,
        MacClippyDatabaseMigration(identifier: "006-search-repair-epoch") { database in
            try database.execute(sql: """
                INSERT OR IGNORE INTO macclippy_search_state(key, value)
                    VALUES ('repair_epoch', 0);
                """)
        }
    ]

    // 3: stop indexing source-app tokens so bare `chat`/`Safari` match content.
    public static let currentSourceProjectionVersion: Int64 = 3

    let database: MacClippyDatabase

    public init(database: MacClippyDatabase) throws {
        self.database = database
        try database.migrate(Self.migrations)
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
            try connection.execute(
                sql: "UPDATE macclippy_search_state SET value = value + 1 WHERE key = 'repair_epoch'"
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

    /// Changes only when a writer reports that its incremental projection was
    /// not committed. A repair snapshots this value and may clear the marker
    /// only if no later writer raised it.
    public func repairEpoch() throws -> Int64 {
        try database.queue.read { connection in
            try Int64.fetchOne(
                connection,
                sql: "SELECT value FROM macclippy_search_state WHERE key = 'repair_epoch'"
            ) ?? 0
        }
    }

    /// Completes a repair atomically with its projection-version update. A
    /// concurrent FTS failure leaves the repair marker set for another pass.
    @discardableResult
    public func completeRepair(expectedEpoch: Int64, sourceProjectionVersion: Int64) throws -> Bool {
        try database.queue.write { connection in
            let currentEpoch = try Int64.fetchOne(
                connection,
                sql: "SELECT value FROM macclippy_search_state WHERE key = 'repair_epoch'"
            ) ?? 0
            guard currentEpoch == expectedEpoch else { return false }
            try connection.execute(
                sql: "UPDATE macclippy_search_state SET value = 0 WHERE key = 'repair_needed'"
            )
            try connection.execute(
                sql: """
                    INSERT INTO macclippy_search_state(key, value)
                    VALUES ('source_projection_version', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [sourceProjectionVersion]
            )
            return true
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

    private static func ftsQuery(for query: String) -> String {
        query.split(whereSeparator: \.isWhitespace)
            .map { token in "\"\(token.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " ")
    }
}

public typealias SearchStore = MacClippySearchStore
