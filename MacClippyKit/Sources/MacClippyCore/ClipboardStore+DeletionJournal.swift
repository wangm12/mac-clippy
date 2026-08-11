import CryptoKit
import Foundation
import GRDB

extension MacClippyClipboardStore {
    public func beginDeletion(ids: [RecordID], now: Date = Date()) throws -> MacClippyDeletionJournalEntry? {
        let orderedIDs = Array(NSOrderedSet(array: ids))
            .compactMap { $0 as? RecordID }
        guard !orderedIDs.isEmpty else { return nil }

        let presentIDs = try Set(metas(for: orderedIDs).map(\.id))
        guard !presentIDs.isEmpty else { return nil }

        var blobIDsByRecord: [RecordID: Set<String>] = [:]
        var allBlobIDs = Set<String>()
        for id in orderedIDs where presentIDs.contains(id) {
            let ids = try blobIDs(for: id)
            blobIDsByRecord[id] = ids
            allBlobIDs.formUnion(ids)
        }

        let operationID = UUID().uuidString
        try database.queue.write { connection in
            try connection.execute(
                sql: "INSERT INTO clipboard_deletion_operations(operation_id, created) VALUES (?, ?)",
                arguments: [operationID, Self.milliseconds(now)]
            )
            for id in orderedIDs where presentIDs.contains(id) {
                try connection.execute(
                    sql: """
                        INSERT INTO clipboard_deletion_records(operation_id, record_id)
                        VALUES (?, ?)
                    """,
                    arguments: [operationID, id.rawValue]
                )
                for blobID in blobIDsByRecord[id] ?? [] {
                    try connection.execute(
                        sql: """
                            INSERT INTO clipboard_deletion_journal(operation_id, record_id, blob_id)
                            VALUES (?, ?, ?)
                        """,
                        arguments: [operationID, id.rawValue, blobID]
                    )
                }
            }
        }

        return MacClippyDeletionJournalEntry(
            operationID: operationID,
            recordIDs: orderedIDs.filter { presentIDs.contains($0) },
            blobIDs: allBlobIDs
        )
    }

    public func pendingDeletions() throws -> [MacClippyDeletionJournalEntry] {
        try pendingDeletions(limit: 128)
    }

    /// Reads a bounded page of pending deletion operations. Recovery callers
    /// should process page zero repeatedly because successful operations are
    /// removed from the journal as they complete.
    public func pendingDeletions(limit: Int) throws -> [MacClippyDeletionJournalEntry] {
        let operationIDs = try pendingDeletionOperationIDs(limit: limit)
        return try operationIDs.map { try deletionJournalEntry(operationID: $0) }
    }

    public func pendingDeletionOperationIDs(limit: Int = 64) throws -> [String] {
        let boundedLimit = max(1, min(limit, 128))
        return try database.queue.read { connection in
            try Row.fetchAll(
                connection,
                sql: "SELECT operation_id FROM clipboard_deletion_operations ORDER BY created ASC LIMIT ?",
                arguments: [boundedLimit]
            ).compactMap { $0["operation_id"] as String? }
        }
    }

    public func deletionRecordIDs(
        operationID: String,
        limit: Int = 256,
        offset: Int = 0
    ) throws -> [RecordID] {
        try database.queue.read { connection in
            try Row.fetchAll(
                connection,
                sql: """
                    SELECT record_id
                    FROM clipboard_deletion_records
                    WHERE operation_id = ?
                    ORDER BY record_id ASC
                    LIMIT ? OFFSET ?
                """,
                arguments: [operationID, max(1, min(limit, 256)), max(0, offset)]
            ).map { row -> RecordID in
                guard let rawID: String = row["record_id"],
                      let id = RecordID(rawValue: rawID) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return id
            }
        }
    }

    public func deletionBlobIDs(
        operationID: String,
        limit: Int = 256,
        offset: Int = 0
    ) throws -> Set<String> {
        try database.queue.read { connection in
            Set(try Row.fetchAll(
                connection,
                sql: """
                    SELECT blob_id
                    FROM clipboard_deletion_journal
                    WHERE operation_id = ?
                    ORDER BY record_id ASC, blob_id ASC
                    LIMIT ? OFFSET ?
                """,
                arguments: [operationID, max(1, min(limit, 256)), max(0, offset)]
            ).compactMap { $0["blob_id"] as String? })
        }
    }

    public func pendingDeletionCount() throws -> Int {
        try database.queue.read { connection in
            try Int.fetchOne(
                connection,
                sql: "SELECT COUNT(*) FROM clipboard_deletion_operations"
            ) ?? 0
        }
    }

    private func deletionJournalEntry(operationID: String) throws -> MacClippyDeletionJournalEntry {
        var recordIDs: [RecordID] = []
        var recordOffset = 0
        while true {
            let page = try deletionRecordIDs(operationID: operationID, offset: recordOffset)
            guard !page.isEmpty else { break }
            recordIDs.append(contentsOf: page)
            guard page.count == 256 else { break }
            recordOffset += page.count
        }

        var blobIDs = Set<String>()
        var blobOffset = 0
        while true {
            let page = try deletionBlobIDs(operationID: operationID, offset: blobOffset)
            guard !page.isEmpty else { break }
            blobIDs.formUnion(page)
            guard page.count == 256 else { break }
            blobOffset += page.count
        }
        return MacClippyDeletionJournalEntry(operationID: operationID, recordIDs: recordIDs, blobIDs: blobIDs)
    }

    public func completeDeletion(operationID: String) throws {
        try database.queue.write { connection in
            try connection.execute(
                sql: "DELETE FROM clipboard_deletion_operations WHERE operation_id = ?",
                arguments: [operationID]
            )
        }
    }

    /// Returns the encrypted inline storage estimate plus external blob IDs.
    /// Blob byte sizes are intentionally resolved by the caller's BlobStore so
    /// this store remains independent of filesystem ownership.
}
