import Foundation
import GRDB

extension MacClippySearchStore {
    static let maintenanceIndexMigration = MacClippyDatabaseMigration(
        identifier: "005-search-maintenance-indexes"
    ) { database in
        if try MacClippySearchStore.requiresProjectionReset(in: database) {
            try database.execute(
                sql: """
                    INSERT INTO macclippy_search_state(key, value)
                    VALUES ('repair_needed', 1)
                    ON CONFLICT(key) DO UPDATE SET value = 1
                    """
            )
            try database.execute(sql: "DELETE FROM macclippy_search_index")
            try database.execute(sql: "DELETE FROM macclippy_search_keys")
            try database.execute(
                sql: "UPDATE macclippy_search_state SET value = value + 1 WHERE key = 'index_revision'"
            )
        }

        try database.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS macclippy_search_keys_rowid_idx
            ON macclippy_search_keys(rowid)
            """)
        try database.execute(sql: """
            CREATE INDEX IF NOT EXISTS macclippy_search_keys_kind_rowid_record_id_idx
            ON macclippy_search_keys(kind, rowid, record_id)
            """)
    }

    private static func requiresProjectionReset(in database: Database) throws -> Bool {
        if try hasDuplicateKeyRowIDs(in: database) { return true }
        if try hasInvalidKeys(in: database) { return true }
        if try hasDanglingKeys(in: database) { return true }
        if try hasUnkeyedIndexRows(in: database) { return true }
        return try hasMismatchedProjection(in: database)
    }

    private static func hasDuplicateKeyRowIDs(in database: Database) throws -> Bool {
        try Row.fetchOne(
            database,
            sql: "SELECT 1 FROM macclippy_search_keys GROUP BY rowid HAVING COUNT(*) > 1 LIMIT 1"
        ) != nil
    }

    private static func hasInvalidKeys(in database: Database) throws -> Bool {
        try Row.fetchOne(
            database,
            sql: """
                SELECT 1 FROM macclippy_search_keys
                WHERE typeof(rowid) != 'integer' OR kind NOT IN (?, ?, ?)
                   OR record_id IS NULL OR trim(record_id) = ''
                LIMIT 1
                """,
            arguments: [
                RecordKind.clipboardItem.rawValue,
                RecordKind.pinboard.rawValue,
                RecordKind.snippet.rawValue
            ]
        ) != nil
    }

    private static func hasDanglingKeys(in database: Database) throws -> Bool {
        try Row.fetchOne(
            database,
            sql: """
                SELECT 1 FROM macclippy_search_keys AS keys
                LEFT JOIN macclippy_search_index AS index_rows ON index_rows.rowid = keys.rowid
                WHERE index_rows.rowid IS NULL LIMIT 1
                """
        ) != nil
    }

    private static func hasUnkeyedIndexRows(in database: Database) throws -> Bool {
        try Row.fetchOne(
            database,
            sql: """
                SELECT 1 FROM macclippy_search_index AS index_rows
                LEFT JOIN macclippy_search_keys AS keys ON keys.rowid = index_rows.rowid
                WHERE keys.rowid IS NULL LIMIT 1
                """
        ) != nil
    }

    private static func hasMismatchedProjection(in database: Database) throws -> Bool {
        try Row.fetchOne(
            database,
            sql: """
                SELECT 1 FROM macclippy_search_keys AS keys
                JOIN macclippy_search_index AS index_rows ON index_rows.rowid = keys.rowid
                WHERE keys.kind != index_rows.kind OR keys.record_id != index_rows.record_id
                LIMIT 1
                """
        ) != nil
    }
}
