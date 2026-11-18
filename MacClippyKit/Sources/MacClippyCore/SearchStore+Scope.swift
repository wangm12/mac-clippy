import Foundation
import GRDB

/// An immutable candidate set shared by successive pages of one search.
/// Its identity lets the connection reuse one TEMP table without retaining
/// an unbounded cache of prior searches or changing the durable index.
public final class MacClippySearchRecordScope: Sendable {
    public let recordIDs: [RecordID]
    let identifier = UUID().uuidString

    public init(recordIDs: [RecordID]) {
        self.recordIDs = recordIDs
    }
}

extension MacClippySearchStore {
    /// A connection-local table avoids SQLite's variable limit without changing
    /// the durable index or its revision. Preparation and matching share the
    /// same queue transaction, so concurrent searches cannot overwrite a scope.
    func prepareSearchScope(_ scope: MacClippySearchRecordScope, on connection: Database) throws {
        try connection.execute(sql: """
            CREATE TEMP TABLE IF NOT EXISTS macclippy_search_scope(
                record_id TEXT PRIMARY KEY NOT NULL
            ) WITHOUT ROWID;
            CREATE TEMP TABLE IF NOT EXISTS macclippy_search_scope_state(
                singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
                identifier TEXT NOT NULL
            );
            """)
        let current = try String.fetchOne(
            connection, sql: "SELECT identifier FROM temp.macclippy_search_scope_state WHERE singleton = 1"
        )
        guard current != scope.identifier else { return }
        try connection.execute(sql: "DELETE FROM temp.macclippy_search_scope")
        let ids = scope.recordIDs
        for start in stride(from: 0, to: ids.count, by: Self.sqliteIDBatchSize) {
            let batch = ids[start..<min(start + Self.sqliteIDBatchSize, ids.count)]
            let placeholders = Array(repeating: "(?)", count: batch.count).joined(separator: ",")
            try connection.execute(
                sql: "INSERT OR IGNORE INTO temp.macclippy_search_scope(record_id) VALUES " + placeholders,
                arguments: StatementArguments(batch.map(\.rawValue))
            )
        }
        try connection.execute(
            sql: "INSERT OR REPLACE INTO temp.macclippy_search_scope_state(singleton, identifier) VALUES (1, ?)",
            arguments: [scope.identifier]
        )
    }
}
