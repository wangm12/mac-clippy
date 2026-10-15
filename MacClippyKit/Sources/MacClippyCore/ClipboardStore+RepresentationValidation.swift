import Foundation
import GRDB

extension MacClippyClipboardStore {
    /// Reads representation metadata without decrypting inline payloads or
    /// loading BlobStore bytes. Search and maintenance use this bounded scan.
    public func validateRepresentations(
        shouldContinue: () -> Bool = { true }
    ) throws {
        let pageSize = 500
        var cursor = MacClippyRepresentationValidationCursor()
        while true {
            guard shouldContinue() else { throw CancellationError() }
            let rows = try representationValidationPage(
                after: cursor,
                limit: pageSize
            )
            guard !rows.isEmpty else { return }
            for row in rows {
                try Self.validateRepresentationRow(row)
            }
            guard rows.count == pageSize, let last = rows.last else { return }
            cursor = MacClippyRepresentationValidationCursor(row: last)
        }
    }

    private func representationValidationPage(
        after cursor: MacClippyRepresentationValidationCursor,
        limit: Int
    ) throws -> [Row] {
        try database.queue.read { connection in
            var sql = """
                SELECT record_id, item_index, sort_order, uti, payload, blob_id, payload_state
                FROM clipboard_representations
            """
            var arguments: [Any] = []
            if let recordID = cursor.recordID,
               let sortOrder = cursor.sortOrder,
               let uti = cursor.uti {
                sql += """
                    WHERE record_id > ?
                       OR (record_id = ? AND sort_order > ?)
                       OR (record_id = ? AND sort_order = ? AND uti > ?)
                """
                arguments += [recordID, recordID, sortOrder, recordID, sortOrder, uti]
            }
            sql += " ORDER BY record_id, sort_order, uti LIMIT ?"
            arguments.append(limit)
            guard let statementArguments = StatementArguments(arguments) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return try Row.fetchAll(connection, sql: sql, arguments: statementArguments)
        }
    }

    private static func validateRepresentationRow(_ row: Row) throws {
        guard let rawRecordID: String = row["record_id"],
              RecordID(rawValue: rawRecordID) != nil,
              let itemIndex: Int = row["item_index"],
              itemIndex >= 0,
              let uti: String = row["uti"],
              !uti.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rawState: String = row["payload_state"],
              let state = MacClippyClipboardRepresentationPayloadState(rawValue: rawState) else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        let payload: Data? = row["payload"]
        let blobID: String? = row["blob_id"]
        switch state {
        case .present:
            guard payload != nil, blobID == nil else { throw MacClippyStoreError.invalidStoredRecord }
        case .spilled:
            guard payload == nil, blobID != nil else { throw MacClippyStoreError.invalidStoredRecord }
        case .unavailable, .oversized:
            guard payload == nil, blobID == nil else { throw MacClippyStoreError.invalidStoredRecord }
        }
    }
}

private struct MacClippyRepresentationValidationCursor {
    var recordID: String?
    var sortOrder: Int?
    var uti: String?

    init() {}

    init(row: Row) {
        recordID = row["record_id"]
        sortOrder = row["sort_order"]
        uti = row["uti"]
    }
}
