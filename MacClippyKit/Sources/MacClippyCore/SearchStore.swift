import Foundation
import GRDB

public struct MacClippySearchHit: Equatable, Sendable {
    public let kind: RecordKind
    public let id: RecordID
    public let snippet: String

    public init(kind: RecordKind, id: RecordID, snippet: String) {
        self.kind = kind
        self.id = id
        self.snippet = snippet
    }
}

public typealias SearchHit = MacClippySearchHit

public final class MacClippySearchStore {
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
        }
    ]

    let database: MacClippyDatabase

    public init(database: MacClippyDatabase) throws {
        self.database = database
        try database.migrate(Self.migrations)
    }

    public func databaseHealth() -> MacClippyDatabaseHealthReport {
        database.healthCheck(requiredTables: [
            "macclippy_search_index",
            "macclippy_search_keys",
            "macclippy_search_state",
            "grdb_migrations"
        ])
    }

    public func databaseRowCount() -> Int64? {
        database.tableRowCount("macclippy_search_keys")
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
    public func repairNeeded() -> Bool {
        (try? database.queue.read { connection in
            (try Int.fetchOne(
                connection,
                sql: "SELECT value FROM macclippy_search_state WHERE key = 'repair_needed'"
            ) ?? 1) != 0
        }) ?? true
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
        }
    }

    public func remove(kind: RecordKind = .clipboardItem, id: RecordID) throws {
        try database.queue.write { connection in
            guard let row = try Row.fetchOne(connection, sql: "SELECT rowid FROM macclippy_search_keys WHERE kind = ? AND record_id = ?", arguments: [kind.rawValue, id.rawValue]) else { return }
            let rowID: Int64 = row["rowid"]
            try connection.execute(sql: "DELETE FROM macclippy_search_index WHERE rowid = ?", arguments: [rowID])
            try connection.execute(sql: "DELETE FROM macclippy_search_keys WHERE rowid = ?", arguments: [rowID])
        }
    }

    public func search(query: String, limit: Int, offset: Int = 0) throws -> [SearchHit] {
        let escaped = Self.ftsQuery(for: query)
        guard !escaped.isEmpty, limit > 0 else { return [] }
        return try database.queue.read { connection in
            try Row.fetchAll(connection, sql: """
                SELECT kind, record_id,
                       snippet(macclippy_search_index, 2, '<', '>', '...', 12) AS snippet
                FROM macclippy_search_index
                WHERE macclippy_search_index MATCH ?
                ORDER BY rank LIMIT ? OFFSET ?
            """, arguments: [escaped, limit, max(0, offset)]).compactMap { row in
                guard let kind = RecordKind(rawValue: row["kind"]),
                      let id = RecordID(rawValue: row["record_id"]) else { return nil }
                return SearchHit(kind: kind, id: id, snippet: row["snippet"])
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
                sql: "SELECT record_id FROM macclippy_search_keys WHERE kind = ?",
                arguments: [kind.rawValue]
            ).compactMap { row in
                RecordID(rawValue: row["record_id"])
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
