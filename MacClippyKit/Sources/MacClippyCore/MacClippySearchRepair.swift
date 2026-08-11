import Foundation
import GRDB

public struct MacClippySearchDocument: Sendable, Equatable {
    public let kind: RecordKind
    public let id: RecordID
    public let text: String

    public init(kind: RecordKind = .clipboardItem, id: RecordID, text: String) {
        self.kind = kind
        self.id = id
        self.text = text
    }
}

public enum MacClippySearchRepairError: Error, Equatable {
    case cancelled
    case documentKindMismatch
    case duplicateDocument
}

public struct MacClippySearchRepairReport: Sendable, Equatable {
    public let documentsWritten: Int
    public let skippedEmptyDocuments: Int
    public let failedDocuments: Int

    public init(documentsWritten: Int, skippedEmptyDocuments: Int, failedDocuments: Int = 0) {
        self.documentsWritten = documentsWritten
        self.skippedEmptyDocuments = skippedEmptyDocuments
        self.failedDocuments = max(0, failedDocuments)
    }
}

extension MacClippySearchStore {
    /// Rebuilds one logical record kind in a single transaction. A thrown
    /// cancellation rolls the transaction back, so a cancelled repair never
    /// leaves a partially rebuilt FTS index. Callers can retry with the same
    /// document snapshot.
    @discardableResult
    public func rebuild(
        documents: [MacClippySearchDocument],
        shouldCancel: () -> Bool = { false }
    ) throws -> MacClippySearchRepairReport {
        // The snapshot API historically accepted documents from more than one
        // logical kind. Preserve that behavior while keeping an empty
        // snapshot useful for clearing the default clipboard projection.
        let kinds = Set(documents.map(\.kind))
        var consumed = false
        return try rebuild(kinds: kinds.isEmpty ? [.clipboardItem] : kinds, pages: {
            guard !consumed else { return nil }
            consumed = true
            return documents
        }, shouldCancel: shouldCancel, deduplicateDocuments: true)
    }

    /// Rebuilds the clipboard index from bounded pages. The page provider is
    /// called inside the same transaction that replaces the FTS rows, so a
    /// cancellation or storage error rolls the rebuild back without keeping a
    /// second full-history document array in memory.
    @discardableResult
    public func rebuild(
        kind: RecordKind = .clipboardItem,
        pages: () throws -> [MacClippySearchDocument]?,
        shouldCancel: () -> Bool = { false }
    ) throws -> MacClippySearchRepairReport {
        try rebuild(
            kinds: [kind],
            pages: pages,
            shouldCancel: shouldCancel,
            deduplicateDocuments: false
        )
    }

    private func rebuild(
        kinds: Set<RecordKind>,
        pages: () throws -> [MacClippySearchDocument]?,
        shouldCancel: () -> Bool,
        deduplicateDocuments: Bool
    ) throws -> MacClippySearchRepairReport {
        try database.queue.write { connection in
            for kind in kinds {
                try Self.delete(kind: kind, from: connection)
            }

            var written = 0
            var skipped = 0
            var seen = Set<String>()
            while true {
                if shouldCancel() { throw MacClippySearchRepairError.cancelled }
                guard let page = try pages() else { break }
                // An empty page is not an end marker: a paged source may have
                // skipped a damaged page while still having healthy records
                // later in the scan. The provider uses nil to signal EOF.
                if page.isEmpty { continue }
                for document in page {
                    if shouldCancel() { throw MacClippySearchRepairError.cancelled }
                    if !kinds.contains(document.kind) {
                        throw MacClippySearchRepairError.documentKindMismatch
                    }
                    let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let key = "\(document.kind.rawValue):\(document.id.rawValue)"
                    if !seen.insert(key).inserted {
                        if deduplicateDocuments {
                            continue
                        }
                        throw MacClippySearchRepairError.duplicateDocument
                    }
                    guard !text.isEmpty else {
                        skipped += 1
                        continue
                    }
                    try Self.insert(document, in: connection, text: text)
                    written += 1
                }
            }
            try connection.execute(
                sql: "UPDATE macclippy_search_state SET value = value + 1 WHERE key = 'index_revision'"
            )
            return MacClippySearchRepairReport(documentsWritten: written, skippedEmptyDocuments: skipped)
        }
    }

    private static func delete(kind: RecordKind, from connection: Database) throws {
        try delete(kinds: [kind], from: connection)
    }

    private static func delete(kinds: Set<RecordKind>, from connection: Database) throws {
        let kindArguments = kinds.map(\.rawValue)
        let placeholders = Array(repeating: "?", count: kindArguments.count).joined(separator: ",")
        let validKindArguments = [
            RecordKind.clipboardItem.rawValue,
            RecordKind.pinboard.rawValue,
            RecordKind.snippet.rawValue
        ]
        let validPlaceholders = Array(repeating: "?", count: validKindArguments.count).joined(separator: ",")

        // Delete rows through both projections. A damaged database may have a
        // key and FTS row disagreeing about kind/record_id; deleting only by
        // the requested kind leaves the other side behind and makes health
        // report the same repair forever.
        try connection.execute(
            sql: """
                DELETE FROM macclippy_search_index
                WHERE rowid IN (
                    SELECT rowid FROM macclippy_search_keys
                    WHERE kind IN (\(placeholders))
                )
                OR kind IN (\(placeholders))
                OR kind NOT IN (\(validPlaceholders))
                OR rowid NOT IN (SELECT rowid FROM macclippy_search_keys)
            """,
            arguments: StatementArguments(kindArguments + kindArguments + validKindArguments)
        )

        try connection.execute(
            sql: """
                DELETE FROM macclippy_search_keys
                WHERE kind IN (\(placeholders))
                   OR kind NOT IN (\(validPlaceholders))
                   OR rowid NOT IN (SELECT rowid FROM macclippy_search_index)
                   OR rowid IN (
                       SELECT keys.rowid
                       FROM macclippy_search_keys AS keys
                       JOIN macclippy_search_index AS rows ON rows.rowid = keys.rowid
                       WHERE keys.kind != rows.kind OR keys.record_id != rows.record_id
                   )
            """,
            arguments: StatementArguments(kindArguments + validKindArguments)
        )

        // The first DELETE can leave a valid key pointing at a mismatched row
        // that was deleted by the kind predicate. Remove any final dangling
        // side so the repair converges even for malformed projections.
        try connection.execute(
            sql: "DELETE FROM macclippy_search_keys WHERE rowid NOT IN (SELECT rowid FROM macclippy_search_index)"
        )
        try connection.execute(
            sql: "DELETE FROM macclippy_search_index WHERE rowid NOT IN (SELECT rowid FROM macclippy_search_keys)"
        )
    }

    private static func insert(_ document: MacClippySearchDocument, in connection: Database, text: String) throws {
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
