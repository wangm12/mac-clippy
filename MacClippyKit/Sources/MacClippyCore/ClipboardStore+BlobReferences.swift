import CryptoKit
import Foundation
import GRDB

extension MacClippyClipboardStore {
    public func isBlobReferenced(_ blobID: String, excluding recordID: RecordID? = nil) throws -> Bool {
        let excluded = recordID.map { Set([$0]) } ?? []
        return try referencedBlobIDs(excluding: excluded).contains(blobID)
    }

    /// Returns every BlobStore identifier still referenced by the database,
    /// optionally ignoring records that are about to be deleted. The legacy
    /// image reference lives inside an encrypted envelope, so it cannot be
    /// resolved with SQL alone; decrypt each surviving envelope once and
    /// share the resulting set across a batch cleanup.
    ///
    /// This replaces the old per-blob `isBlobReferenced` scan. A delete or
    /// retention batch now performs one O(N) reference pass instead of one
    /// full-history pass for every blob candidate.

    public func referencedBlobIDs(
        excluding recordIDs: Set<RecordID> = [],
        shouldContinue: () -> Bool = { true }
    ) throws -> Set<String> {
        guard shouldContinue() else { throw CancellationError() }
        var ids = try allRepresentationBlobIDs(shouldContinue: shouldContinue)
        if !recordIDs.isEmpty {
            // Keep the exclusion bounded and independent of SQLite's variable
            // limit. Fetch only the representation blobs belonging to records
            // being deleted, then remove them from the full reference set.
            for batch in Self.idBatches(Array(recordIDs)) {
                guard shouldContinue() else { throw CancellationError() }
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
                let excluded = try database.queue.read { connection in
                    try Row.fetchAll(
                        connection,
                        sql: "SELECT DISTINCT blob_id FROM clipboard_representations WHERE record_id IN (\(placeholders)) AND blob_id IS NOT NULL",
                        arguments: StatementArguments(batch.map(\.rawValue))
                    ).compactMap { $0["blob_id"] as String? }
                }
                ids.subtract(excluded)
            }
        }
        // Validate the authenticated body discriminator before collecting
        // legacy image references. The stored content_kind column is not
        // sufficient for a destructive reachability decision.
        var cursor: MacClippyClipboardHistoryCursor?
        let pageSize = 256
        while true {
            guard shouldContinue() else { throw CancellationError() }
            let page = try list(limit: pageSize, before: cursor)
            guard !page.isEmpty else { break }
            for meta in page where !recordIDs.contains(meta.id) {
                // A failed decrypt/decode is not evidence that the record has no
                // Blob reference. Propagate the error so deletion/retention
                // aborts before it can delete a Blob belonging to a corrupt
                // record.
                let body = try body(for: meta.id)
                guard meta.contentKind == nil || body.contentKind == meta.contentKind else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                if let blobID = body.imageBlobID {
                    ids.insert(blobID)
                }
            }
            guard page.count == pageSize, let last = page.last else { break }
            cursor = MacClippyClipboardHistoryCursor(
                modified: last.modified,
                lamport: last.lamport,
                id: last.id
            )
        }
        return ids
    }

    /// Returns the candidate blobs that are no longer referenced by any
    /// surviving record. Unlike `referencedBlobIDs`, this scan keeps only the
    /// caller's candidate set in memory; deletion and retention must not
    /// materialize every historical Blob ID just to decide whether a small
    /// batch can be reclaimed.
    public func unreferencedBlobIDs(
        _ candidateIDs: Set<String>,
        excluding recordIDs: Set<RecordID> = [],
        shouldContinue: () -> Bool = { true }
    ) throws -> Set<String> {
        guard shouldContinue() else { throw CancellationError() }
        guard !candidateIDs.isEmpty else { return [] }

        var remaining = candidateIDs
        let candidateList = Array(candidateIDs)
        for start in stride(from: 0, to: candidateList.count, by: Self.sqliteIDBatchSize) {
            guard shouldContinue() else { throw CancellationError() }
            let batch = Array(candidateList[start ..< min(start + Self.sqliteIDBatchSize, candidateList.count)])
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let referenced = try database.queue.read { connection in
                return try Row.fetchAll(
                    connection,
                    sql: "SELECT DISTINCT blob_id FROM clipboard_representations WHERE blob_id IN (\(placeholders)) AND blob_id IS NOT NULL",
                    arguments: StatementArguments(batch)
                ).compactMap { $0["blob_id"] as String? }
            }
            remaining.subtract(referenced)
        }

        var cursor: MacClippyClipboardHistoryCursor?
        let pageSize = 256
        while !remaining.isEmpty {
            guard shouldContinue() else { throw CancellationError() }
            let page = try list(limit: pageSize, before: cursor)
            guard !page.isEmpty else { break }
            for meta in page where !recordIDs.contains(meta.id) {
                guard shouldContinue() else { throw CancellationError() }
                let body = try body(for: meta.id)
                guard meta.contentKind == nil || body.contentKind == meta.contentKind else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                if let blobID = body.imageBlobID {
                    remaining.remove(blobID)
                }
            }
            guard page.count == pageSize, let last = page.last else { break }
            cursor = MacClippyClipboardHistoryCursor(
                modified: last.modified,
                lamport: last.lamport,
                id: last.id
            )
        }
        return remaining
    }

    // Returns every external Blob referenced by a record, including the
    // legacy primary image payload and oversized representation rows. Callers
    // use this before deleting the parent row so all of the record's files can
    // be reclaimed immediately instead of waiting for startup reconciliation.

    public func blobIDs(for id: RecordID) throws -> Set<String> {
        var ids = Set<String>()
        guard !(try metas(for: [id]).isEmpty) else {
            throw MacClippyStoreError.recordNotFound
        }
        guard let persistedKind = try contentKinds(for: [id])[id] else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        let record = try body(for: id)
        guard record.contentKind == persistedKind else {
            // The legacy primary image blob is only reachable through the
            // authenticated envelope. Never trust a stale discriminator when
            // building a destructive deletion journal.
            throw MacClippyStoreError.invalidStoredRecord
        }
        if let primary = record.imageBlobID {
            ids.insert(primary)
        }
        let representationIDs = try database.queue.read { connection in
            try Row.fetchAll(
                connection,
                sql: "SELECT blob_id FROM clipboard_representations WHERE record_id = ? AND blob_id IS NOT NULL",
                arguments: [id.rawValue]
            ).compactMap { $0["blob_id"] as String? }
        }
        ids.formUnion(representationIDs)
        return ids
    }

    /// Persists a deletion intent before callers touch the other stores. A
    /// journal with no blob rows is still retained in the operations table,
    /// so records without external payloads are recoverable too.

    public func representations(for id: RecordID) throws -> [MacClippyClipboardRepresentation] {
        try database.queue.read { connection in
                let rows = try Row.fetchAll(
                connection,
                sql: "SELECT uti, payload, blob_id, payload_state FROM clipboard_representations WHERE record_id = ? ORDER BY sort_order ASC",
                arguments: [id.rawValue]
                )
            return try rows.map { row in
                let uti: String = row["uti"]
                let blobID: String? = row["blob_id"]
                let payload: Data? = row["payload"]
                let stateString: String? = row["payload_state"]
                guard let stateString,
                      let payloadState = MacClippyClipboardRepresentationPayloadState(rawValue: stateString) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }

                switch payloadState {
                case .unavailable:
                    guard payload == nil, blobID == nil else {
                        throw MacClippyStoreError.invalidStoredRecord
                    }
                    return MacClippyClipboardRepresentation(uti: uti, payloadBytes: nil, blobID: nil, payloadState: .unavailable)
                case .oversized:
                    guard payload == nil, blobID == nil else {
                        throw MacClippyStoreError.invalidStoredRecord
                    }
                    return MacClippyClipboardRepresentation(uti: uti, payloadBytes: nil, blobID: nil, payloadState: .oversized)
                case .spilled:
                    guard payload == nil, blobID != nil else {
                        throw MacClippyStoreError.invalidStoredRecord
                    }
                    return MacClippyClipboardRepresentation(uti: uti, payloadBytes: nil, blobID: blobID, payloadState: .spilled)
                case .present:
                    guard let payload, blobID == nil else {
                        throw MacClippyStoreError.invalidStoredRecord
                    }
                    do {
                        let decryptedPayload = try MacClippyCipher.open(
                            MacClippyEnvelope(combined: payload),
                            with: key
                        )
                        return MacClippyClipboardRepresentation(
                            uti: uti,
                            payloadBytes: decryptedPayload,
                            blobID: nil,
                            payloadState: .present
                        )
                    } catch let error as MacClippyCipherError {
                        // Authentication failures can mean the device key is
                        // wrong or unavailable; do not relabel them as a
                        // single corrupt representation.
                        throw error
                    } catch {
                        // A corrupted representation must remain observable as
                        // damaged storage. Returning empty Data would make the
                        // UI report a usable empty payload and could turn a
                        // failed copy/paste into a misleading success.
                        throw MacClippyStoreError.invalidStoredRecord
                    }
                }
            }
        }
    }

    /// Restores the complete representation side table for an existing record.
    /// This is used by edit rollback: updating a text record can replace a
    /// spilled primary representation with an inline payload, so restoring
    /// only the encrypted envelope would lose the original blob reference.
    /// The method never creates or deletes BlobStore files; it only restores
    /// rows that were already present in the caller's snapshot.
    public func replaceRepresentations(
        for id: RecordID,
        with representations: [MacClippyClipboardRepresentation]
    ) throws {
        var seenUTIs = Set<String>()
        let preparedRows = try representations.enumerated().map { index, representation -> (
            sortOrder: Int,
            uti: String,
            payload: Data?,
            blobID: String?,
            state: MacClippyClipboardRepresentationPayloadState
        ) in
            guard !representation.uti.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seenUTIs.insert(representation.uti).inserted else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            switch representation.payloadState {
            case .present:
                guard let payloadBytes = representation.payloadBytes,
                      representation.blobID == nil else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return (
                    index,
                    representation.uti,
                    try MacClippyCipher.seal(payloadBytes, with: key).combined,
                    nil,
                    .present
                )
            case .spilled:
                guard representation.payloadBytes == nil,
                      let blobID = representation.blobID,
                      !blobID.isEmpty else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return (index, representation.uti, nil, blobID, .spilled)
            case .unavailable, .oversized:
                guard representation.payloadBytes == nil, representation.blobID == nil else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return (index, representation.uti, nil, nil, representation.payloadState)
            }
        }

        try database.queue.write { connection in
            guard try Row.fetchOne(
                connection,
                sql: "SELECT 1 FROM clipboard_records WHERE id = ?",
                arguments: [id.rawValue]
            ) != nil else {
                throw MacClippyStoreError.recordNotFound
            }
            try connection.execute(
                sql: "DELETE FROM clipboard_representations WHERE record_id = ?",
                arguments: [id.rawValue]
            )
            for row in preparedRows {
                try connection.execute(
                    sql: """
                        INSERT INTO clipboard_representations
                            (record_id, sort_order, uti, payload, blob_id, payload_state)
                        VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        id.rawValue,
                        row.sortOrder,
                        row.uti,
                        row.payload,
                        row.blobID,
                        row.state.rawValue
                    ]
                )
            }
        }
    }

    /// Reads representation state and sizes without decrypting inline payloads.
    /// Details and diagnostics should use this projection; payload decryption
    /// remains reserved for copy/paste, preview and export.
    public func representationMetadata(for id: RecordID) throws -> [MacClippyClipboardRepresentationMetadata] {
        try database.queue.read { connection in
            let rows = try Row.fetchAll(
                connection,
                sql: "SELECT uti, payload, blob_id, payload_state FROM clipboard_representations WHERE record_id = ? ORDER BY sort_order ASC",
                arguments: [id.rawValue]
            )
            return try rows.map { row in
                let uti: String = row["uti"]
                let payload: Data? = row["payload"]
                let blobID: String? = row["blob_id"]
                guard !uti.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let stateString: String = row["payload_state"],
                      let state = MacClippyClipboardRepresentationPayloadState(rawValue: stateString) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                switch state {
                case .present:
                    guard payload != nil, blobID == nil else { throw MacClippyStoreError.invalidStoredRecord }
                case .spilled:
                    guard payload == nil, blobID != nil else { throw MacClippyStoreError.invalidStoredRecord }
                case .unavailable, .oversized:
                    guard payload == nil, blobID == nil else { throw MacClippyStoreError.invalidStoredRecord }
                }
                return MacClippyClipboardRepresentationMetadata(
                    uti: uti,
                    payloadState: state,
                    inlineByteCount: payload?.count ?? 0,
                    blobID: blobID
                )
            }
        }
    }

    /// Reads only representation metadata needed to build a search
    /// projection. It intentionally does not decrypt inline payloads or read
    /// BlobStore bytes; copy/paste and export remain the payload boundaries.
    public func validateRepresentations(
        shouldContinue: () -> Bool = { true }
    ) throws {
        let pageSize = 500
        var lastRecordID: String?
        var lastSortOrder: Int?
        var lastUTI: String?
        while true {
            guard shouldContinue() else { throw CancellationError() }
            let rows = try database.queue.read { connection in
                var sql = """
                    SELECT record_id, sort_order, uti, payload, blob_id, payload_state
                    FROM clipboard_representations
                """
                var arguments: [Any] = []
                if let lastRecordID, let lastSortOrder, let lastUTI {
                    sql += """
                        WHERE record_id > ?
                           OR (record_id = ? AND sort_order > ?)
                           OR (record_id = ? AND sort_order = ? AND uti > ?)
                    """
                    arguments += [lastRecordID, lastRecordID, lastSortOrder, lastRecordID, lastSortOrder, lastUTI]
                }
                sql += " ORDER BY record_id, sort_order, uti LIMIT ?"
                arguments.append(pageSize)
                guard let statementArguments = StatementArguments(arguments) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return try Row.fetchAll(
                    connection,
                    sql: sql,
                    arguments: statementArguments
                )
            }
            guard !rows.isEmpty else { return }
            for row in rows {
                guard let rawRecordID: String = row["record_id"],
                      RecordID(rawValue: rawRecordID) != nil,
                      let uti: String = row["uti"],
                      !uti.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty,
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
            guard rows.count == pageSize, let last = rows.last else { return }
            lastRecordID = last["record_id"]
            lastSortOrder = last["sort_order"]
            lastUTI = last["uti"]
        }
    }

    /// Returns the subset of `ids` that stored a representation with `uti`.
    /// Used to badge Universal Clipboard items from `com.apple.is-remote-clipboard`
    /// without adding a column or decrypting payloads.
    public func recordIDsContainingUTI(_ uti: String, in ids: [RecordID]) throws -> Set<RecordID> {
        guard !ids.isEmpty, !uti.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        var found: Set<RecordID> = []
        for batch in Self.idBatches(ids) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let rows = try database.queue.read { connection in
                try Row.fetchAll(
                    connection,
                    sql: """
                        SELECT DISTINCT record_id
                        FROM clipboard_representations
                        WHERE uti = ? AND record_id IN (\(placeholders))
                    """,
                    arguments: StatementArguments([uti] + batch.map(\.rawValue))
                )
            }
            for row in rows {
                guard let rawID: String = row["record_id"],
                      let id = RecordID(rawValue: rawID) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                found.insert(id)
            }
        }
        return found
    }

    public func representationUTIs(for id: RecordID) throws -> [String] {
        try database.queue.read { connection in
            let rows = try Row.fetchAll(
                connection,
                sql: "SELECT uti, payload, blob_id, payload_state FROM clipboard_representations WHERE record_id = ? ORDER BY sort_order ASC",
                arguments: [id.rawValue]
            )
            return try rows.map { row in
                guard let uti: String = row["uti"],
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
                return uti
            }
        }
    }

    // All BlobStore identifiers referenced by the representation side table.
    // Used by startup reconciliation to detect orphan blobs that are no longer
    // referenced by any record (e.g. after a crash mid-capture).

    public func allRepresentationBlobIDs(
        shouldContinue: () -> Bool = { true }
    ) throws -> Set<String> {
        var result = Set<String>()
        let pageSize = 256
        var lastBlobID: String?
        while true {
            guard shouldContinue() else { throw CancellationError() }
            let page = try database.queue.read { connection in
                var sql = "SELECT DISTINCT blob_id FROM clipboard_representations WHERE blob_id IS NOT NULL"
                var arguments: [Any] = []
                if let lastBlobID {
                    sql += " AND blob_id > ?"
                    arguments.append(lastBlobID)
                }
                sql += " ORDER BY blob_id LIMIT ?"
                arguments.append(pageSize)
                guard let statementArguments = StatementArguments(arguments) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return try Row.fetchAll(
                    connection,
                    sql: sql,
                    arguments: statementArguments
                ).compactMap { $0["blob_id"] as String? }
            }
            result.formUnion(page)
            guard page.count == pageSize, let last = page.last else { return result }
            lastBlobID = last
        }
    }

    /// Streams distinct representation blob references in bounded SQL pages.
    /// This is the reconciliation path; `allRepresentationBlobIDs()` remains
    /// as a compatibility API for callers that explicitly request a set.
    public func forEachRepresentationBlobID(
        shouldContinue: () -> Bool = { true },
        _ body: (String) throws -> Void
    ) throws {
        let pageSize = 256
        var lastBlobID: String?
        while true {
            guard shouldContinue() else { throw CancellationError() }
            let page = try database.queue.read { connection in
                var sql = "SELECT DISTINCT blob_id FROM clipboard_representations WHERE blob_id IS NOT NULL"
                var arguments: [Any] = []
                if let lastBlobID {
                    sql += " AND blob_id > ?"
                    arguments.append(lastBlobID)
                }
                sql += " ORDER BY blob_id LIMIT ?"
                arguments.append(pageSize)
                guard let statementArguments = StatementArguments(arguments) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return try Row.fetchAll(
                    connection,
                    sql: sql,
                    arguments: statementArguments
                ).compactMap { $0["blob_id"] as String? }
            }
            for blobID in page {
                guard shouldContinue() else { throw CancellationError() }
                try body(blobID)
            }
            guard page.count == pageSize, let last = page.last else { return }
            lastBlobID = last
        }
    }

    // Removes every representation row for a record. The 002 migration sets
    // ON DELETE CASCADE on the side table, so delete(id:) already cascades
    // when foreign_keys is on; this method exists so reconciliation and tests
    // can drop representations without deleting the parent record.

    public func deleteRepresentations(for id: RecordID) throws {
        try database.queue.write { connection in
            try connection.execute(
                sql: "DELETE FROM clipboard_representations WHERE record_id = ?",
                arguments: [id.rawValue]
            )
        }
    }
}
