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
        try database.queue.write { connection in
            let kinds = Set(documents.map { $0.kind.rawValue })
            for kind in kinds {
                try connection.execute(
                    sql: "DELETE FROM macclippy_search_index WHERE rowid IN (SELECT rowid FROM macclippy_search_keys WHERE kind = ?)",
                    arguments: [kind]
                )
                try connection.execute(
                    sql: "DELETE FROM macclippy_search_keys WHERE kind = ?",
                    arguments: [kind]
                )
            }

            var written = 0
            var skipped = 0
            var seen = Set<String>()
            for document in documents {
                if shouldCancel() { throw MacClippySearchRepairError.cancelled }
                let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = "\(document.kind.rawValue):\(document.id.rawValue)"
                guard seen.insert(key).inserted else { continue }
                guard !text.isEmpty else {
                    skipped += 1
                    continue
                }
                try Self.insert(document, in: connection, text: text)
                written += 1
            }
            return MacClippySearchRepairReport(documentsWritten: written, skippedEmptyDocuments: skipped)
        }
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
