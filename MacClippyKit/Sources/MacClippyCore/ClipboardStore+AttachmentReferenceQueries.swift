import Foundation
import GRDB

struct MacClippyBlobReferenceCursor {
    let blobID: String
    let recordID: String
    let uti: String?
}

struct MacClippyBlobReferenceRow {
    let recordID: String
    let blobID: String
    let uti: String?
}

enum MacClippyBlobReferenceIndexPolicy {
    static let pageSize = 64
}

struct MacClippyBlobReferenceQuery {
    let table: String
    let blobColumn: String
    let ownerColumn: String
    let utiColumn: String?
}

struct MacClippyBlobCandidateQuery {
    let candidates: [String]
    let table: String
    let blobColumn: String
    let ownerColumn: String
    let excluding: Set<RecordID>
}

extension MacClippyClipboardStore {
    func forEachDistinctBlobID(
        sqlColumn: String,
        table: String,
        shouldContinue: () -> Bool,
        _ body: (String) throws -> Void
    ) throws {
        var cursor: String?
        while true {
            guard shouldContinue() else { throw CancellationError() }
            let page = try database.queue.read { connection -> [String] in
                try assertAttachmentReferenceIndexVerified(on: connection)
                var sql = """
                    SELECT DISTINCT \(sqlColumn) FROM \(table)
                    WHERE \(sqlColumn) IS NOT NULL AND \(sqlColumn) != ''
                    """
                var arguments: [Any] = []
                if let cursor {
                    sql += " AND \(sqlColumn) > ?"
                    arguments.append(cursor)
                }
                sql += " ORDER BY \(sqlColumn) LIMIT ?"
                arguments.append(MacClippyBlobReferenceIndexPolicy.pageSize)
                guard let statementArguments = StatementArguments(arguments) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return try String.fetchAll(connection, sql: sql, arguments: statementArguments)
            }
            guard !page.isEmpty else { return }
            for blobID in page {
                guard shouldContinue() else { throw CancellationError() }
                try body(blobID)
            }
            guard page.count == MacClippyBlobReferenceIndexPolicy.pageSize, let last = page.last else { return }
            cursor = last
        }
    }

    func forEachBlobReference(
        query: MacClippyBlobReferenceQuery,
        excluding recordIDs: Set<RecordID>,
        shouldContinue: () -> Bool,
        _ body: (String) throws -> Void
    ) throws {
        var cursor: MacClippyBlobReferenceCursor?
        while true {
            guard shouldContinue() else { throw CancellationError() }
            let rows = try fetchBlobReferencePage(query: query, after: cursor)
            guard !rows.isEmpty else { return }
            for row in rows {
                guard shouldContinue() else { throw CancellationError() }
                guard let id = RecordID(rawValue: row.recordID) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                if !recordIDs.contains(id) { try body(row.blobID) }
            }
            guard rows.count == MacClippyBlobReferenceIndexPolicy.pageSize, let last = rows.last else { return }
            cursor = MacClippyBlobReferenceCursor(blobID: last.blobID, recordID: last.recordID, uti: last.uti)
        }
    }

    private func fetchBlobReferencePage(
        query: MacClippyBlobReferenceQuery,
        after cursor: MacClippyBlobReferenceCursor?
    ) throws -> [MacClippyBlobReferenceRow] {
        try database.queue.read { connection in
            try assertAttachmentReferenceIndexVerified(on: connection)
            var sql = "SELECT \(query.blobColumn) AS blob_id, \(query.ownerColumn) AS record_id"
            if let utiColumn = query.utiColumn { sql += ", \(utiColumn) AS uti" }
            sql += " FROM \(query.table) WHERE \(query.blobColumn) IS NOT NULL AND \(query.blobColumn) != ''"
            let arguments = query.cursorArguments(after: cursor)
            if !arguments.isEmpty { sql += query.cursorPredicate }
            sql += query.orderingClause
            var statementArguments = arguments
            statementArguments.append(MacClippyBlobReferenceIndexPolicy.pageSize)
            guard let values = StatementArguments(statementArguments) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return try Row.fetchAll(connection, sql: sql, arguments: values).map { row in
                guard let blobID: String = row["blob_id"],
                      let recordID: String = row["record_id"] else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return MacClippyBlobReferenceRow(recordID: recordID, blobID: blobID, uti: row["uti"])
            }
        }
    }

    func removeReferencedCandidates(
        _ request: MacClippyBlobCandidateQuery,
        from unreferenced: inout Set<String>,
        shouldContinue: () -> Bool,
        on connection: Database
    ) throws {
        let placeholders = Array(repeating: "?", count: request.candidates.count).joined(separator: ",")
        let sql = """
            SELECT \(request.blobColumn) AS blob_id, \(request.ownerColumn) AS record_id
            FROM \(request.table) WHERE \(request.blobColumn) IN (\(placeholders))
            """
        let rows = try Row.fetchCursor(connection, sql: sql, arguments: StatementArguments(request.candidates))
        while let row = try rows.next() {
            guard shouldContinue() else { throw CancellationError() }
            guard let blobID: String = row["blob_id"],
                  let rawRecordID: String = row["record_id"],
                  let recordID = RecordID(rawValue: rawRecordID) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            if !request.excluding.contains(recordID) { unreferenced.remove(blobID) }
        }
    }
}

private extension MacClippyBlobReferenceQuery {
    var cursorPredicate: String {
        guard let utiColumn else {
            return " AND (\(blobColumn) > ? OR (\(blobColumn) = ? AND \(ownerColumn) > ?))"
        }
        return " AND (\(blobColumn) > ? OR (\(blobColumn) = ? AND "
            + "(\(ownerColumn) > ? OR (\(ownerColumn) = ? AND \(utiColumn) > ?))))"
    }

    var orderingClause: String {
        let utiOrdering = utiColumn.map { ", \($0)" } ?? ""
        return " ORDER BY \(blobColumn), \(ownerColumn)\(utiOrdering) LIMIT ?"
    }

    func cursorArguments(after cursor: MacClippyBlobReferenceCursor?) -> [Any] {
        guard let cursor else { return [] }
        var arguments: [Any] = [cursor.blobID, cursor.blobID, cursor.recordID]
        if utiColumn != nil {
            arguments.append(cursor.recordID)
            arguments.append(cursor.uti ?? "")
        }
        return arguments
    }
}
