import CryptoKit
import Foundation
import GRDB

public final class MacClippyPinboardStore {
    public static let migrations: [MacClippyDatabaseMigration] = [
        MacClippyDatabaseMigration(identifier: "001-pinboard-core") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS macclippy_pinboards(
                    id TEXT PRIMARY KEY NOT NULL, sort_order INTEGER NOT NULL,
                    envelope BLOB NOT NULL, modified INTEGER NOT NULL
                );
            """)
        }
    ]

    private let database: MacClippyDatabase
    private let key: SymmetricKey

    public init(database: MacClippyDatabase, deviceKey: SymmetricKey) throws {
        self.database = database
        key = deviceKey
        try database.migrate(Self.migrations)
    }

    public func databaseHealth() -> MacClippyDatabaseHealthReport {
        database.healthCheck(requiredTables: ["macclippy_pinboards", "grdb_migrations"])
    }

    public func databaseRowCount() -> Int64? {
        database.tableRowCount("macclippy_pinboards")
    }

    @discardableResult
    public func create(name: String, color: String? = nil) throws -> Pinboard {
        let board = Pinboard(name: name, color: color)
        try persist(board, order: try nextOrder())
        return board
    }

    public func list() throws -> [Pinboard] {
        try database.queue.read { connection in
            try Row.fetchAll(connection, sql: "SELECT envelope FROM macclippy_pinboards ORDER BY sort_order ASC").map(decode)
        }
    }

    public func fetch(id: RecordID) throws -> Pinboard {
        try database.queue.read { connection in
            guard let row = try Row.fetchOne(connection, sql: "SELECT envelope FROM macclippy_pinboards WHERE id = ?", arguments: [id.rawValue]) else {
                throw MacClippyStoreError.recordNotFound
            }
            return try decode(row)
        }
    }

    public func update(_ board: Pinboard) throws {
        let envelope = try MacClippyCipher.seal(try JSONEncoder().encode(board), with: key)
        try database.queue.write { connection in
            try connection.execute(sql: "UPDATE macclippy_pinboards SET envelope = ?, modified = ? WHERE id = ?", arguments: [envelope.combined, board.modified.timeIntervalSince1970, board.id.rawValue])
        }
    }

    public func rename(id: RecordID, to name: String) throws {
        var board = try fetch(id: id)
        board.name = name
        board.modified = Date()
        try update(board)
    }

    @discardableResult
    public func mutate(id: RecordID, _ change: (inout Pinboard) -> Void) throws -> Pinboard {
        var board = try fetch(id: id)
        change(&board)
        board.modified = Date()
        try update(board)
        return board
    }

    public func addItem(_ itemID: RecordID, to pinboardID: RecordID, at index: Int? = nil) throws {
        _ = try mutate(id: pinboardID) { board in
            board.itemIDs.removeAll { $0 == itemID }
            if let index, board.itemIDs.indices.contains(index) {
                board.itemIDs.insert(itemID, at: index)
            } else {
                board.itemIDs.append(itemID)
            }
        }
    }

    public func removeItem(_ itemID: RecordID, from pinboardID: RecordID) throws {
        _ = try mutate(id: pinboardID) { $0.itemIDs.removeAll { $0 == itemID } }
    }

    public func reorder(orderedIDs: [RecordID]) throws {
        try database.queue.write { connection in
            for (index, id) in orderedIDs.enumerated() {
                try connection.execute(sql: "UPDATE macclippy_pinboards SET sort_order = ? WHERE id = ?", arguments: [index, id.rawValue])
            }
        }
    }

    public func delete(id: RecordID) throws {
        try database.queue.write { connection in
            try connection.execute(sql: "DELETE FROM macclippy_pinboards WHERE id = ?", arguments: [id.rawValue])
        }
    }

    public static func protectedIDs(from store: MacClippyPinboardStore) throws -> Set<RecordID> {
        try store.list().reduce(into: Set<RecordID>()) { result, board in result.formUnion(board.itemIDs) }
    }

    private func persist(_ board: Pinboard, order: Int) throws {
        let envelope = try MacClippyCipher.seal(try JSONEncoder().encode(board), with: key)
        try database.queue.write { connection in
            try connection.execute(sql: "INSERT INTO macclippy_pinboards(id, sort_order, envelope, modified) VALUES (?, ?, ?, ?)", arguments: [board.id.rawValue, order, envelope.combined, board.modified.timeIntervalSince1970])
        }
    }

    private func nextOrder() throws -> Int {
        try database.queue.read { connection in (try Int.fetchOne(connection, sql: "SELECT MAX(sort_order) FROM macclippy_pinboards") ?? -1) + 1 }
    }

    private func decode(_ row: Row) throws -> Pinboard {
        guard let data = row["envelope"] as Data? else { throw MacClippyStoreError.invalidStoredRecord }
        return try JSONDecoder().decode(Pinboard.self, from: MacClippyCipher.open(MacClippyEnvelope(combined: data), with: key))
    }
}

public typealias PinboardStore = MacClippyPinboardStore

public final class MacClippySnippetStore {
    public static let migrations: [MacClippyDatabaseMigration] = [
        MacClippyDatabaseMigration(identifier: "001-snippet-core") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS macclippy_snippets(
                    id TEXT PRIMARY KEY NOT NULL, trigger_value TEXT UNIQUE,
                    envelope BLOB NOT NULL, modified INTEGER NOT NULL
                );
            """)
        }
    ]

    private let database: MacClippyDatabase
    private let key: SymmetricKey

    public init(database: MacClippyDatabase, deviceKey: SymmetricKey) throws {
        self.database = database
        key = deviceKey
        try database.migrate(Self.migrations)
    }

    public func databaseHealth() -> MacClippyDatabaseHealthReport {
        database.healthCheck(requiredTables: ["macclippy_snippets", "grdb_migrations"])
    }

    public func databaseRowCount() -> Int64? {
        database.tableRowCount("macclippy_snippets")
    }

    @discardableResult
    public func create(name: String, body: String, trigger: String? = nil) throws -> Snippet {
        let snippet = Snippet(name: name, body: body, trigger: trigger)
        try persist(snippet)
        return snippet
    }

    public func list() throws -> [Snippet] {
        try database.queue.read { connection in try Row.fetchAll(connection, sql: "SELECT envelope FROM macclippy_snippets ORDER BY modified DESC").map(decode) }
    }

    public func fetch(id: RecordID) throws -> Snippet {
        try database.queue.read { connection in
            guard let row = try Row.fetchOne(connection, sql: "SELECT envelope FROM macclippy_snippets WHERE id = ?", arguments: [id.rawValue]) else { throw MacClippyStoreError.recordNotFound }
            return try decode(row)
        }
    }

    public func find(trigger: String) throws -> Snippet? {
        try database.queue.read { connection in
            guard let row = try Row.fetchOne(connection, sql: "SELECT envelope FROM macclippy_snippets WHERE trigger_value = ?", arguments: [trigger]) else { return nil }
            return try decode(row)
        }
    }

    public func update(id: RecordID, name: String, body: String, trigger: String?) throws {
        var snippet = try fetch(id: id)
        snippet.name = name
        snippet.body = body
        snippet.trigger = trigger
        snippet.modified = Date()
        try update(snippet)
    }

    public func update(_ snippet: Snippet) throws {
        let envelope = try MacClippyCipher.seal(try JSONEncoder().encode(snippet), with: key)
        try database.queue.write { connection in
            try connection.execute(sql: "UPDATE macclippy_snippets SET trigger_value = ?, envelope = ?, modified = ? WHERE id = ?", arguments: [snippet.trigger, envelope.combined, snippet.modified.timeIntervalSince1970, snippet.id.rawValue])
        }
    }

    public func delete(id: RecordID) throws {
        try database.queue.write { connection in try connection.execute(sql: "DELETE FROM macclippy_snippets WHERE id = ?", arguments: [id.rawValue]) }
    }

    private func persist(_ snippet: Snippet) throws {
        let envelope = try MacClippyCipher.seal(try JSONEncoder().encode(snippet), with: key)
        try database.queue.write { connection in
            try connection.execute(sql: "INSERT INTO macclippy_snippets(id, trigger_value, envelope, modified) VALUES (?, ?, ?, ?)", arguments: [snippet.id.rawValue, snippet.trigger, envelope.combined, snippet.modified.timeIntervalSince1970])
        }
    }

    private func decode(_ row: Row) throws -> Snippet {
        guard let data = row["envelope"] as Data? else { throw MacClippyStoreError.invalidStoredRecord }
        return try JSONDecoder().decode(Snippet.self, from: MacClippyCipher.open(MacClippyEnvelope(combined: data), with: key))
    }
}

public typealias SnippetStore = MacClippySnippetStore
