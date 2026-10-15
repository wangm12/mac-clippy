import CryptoKit
import Foundation
import GRDB

extension MacClippyClipboardStore {
    public func isBlobReferenced(_ blobID: String, excluding recordID: RecordID? = nil) throws -> Bool {
        let excluded = recordID.map { Set([$0]) } ?? []
        return try hasReferencedBlob(blobID, excluding: excluded)
    }

    /// Returns all indexed BlobStore identifiers, optionally excluding
    /// references owned only by records being deleted. Shared references from
    /// surviving rows remain present.
    public func referencedBlobIDs(
        excluding recordIDs: Set<RecordID> = [],
        shouldContinue: () -> Bool = { true }
    ) throws -> Set<String> {
        try referencedBlobIDsFromVerifiedIndex(excluding: recordIDs, shouldContinue: shouldContinue)
    }

    /// Image blob IDs from unencrypted columns / representation rows.
    /// Settings storage must not open every image envelope.
    public func imageBlobIDs() throws -> Set<String> {
        try backfillMissingPrimaryImageBlobIDs()
        return try database.queue.read { connection in
            let primary = try String.fetchAll(
                connection,
                sql: """
                    SELECT primary_blob_id FROM clipboard_records
                    WHERE content_kind = ?
                      AND primary_blob_id IS NOT NULL
                      AND trim(primary_blob_id) != ''
                    """,
                arguments: [MacClippyContentKind.image.rawValue]
            )
            let representations = try String.fetchAll(
                connection,
                sql: """
                    SELECT DISTINCT r.blob_id
                    FROM clipboard_representations r
                    JOIN clipboard_records c ON c.id = r.record_id
                    WHERE c.content_kind = ?
                      AND r.blob_id IS NOT NULL
                      AND trim(r.blob_id) != ''
                    """,
                arguments: [MacClippyContentKind.image.rawValue]
            )
            return Set(primary + representations)
        }
    }

    func backfillMissingPrimaryImageBlobIDs() throws {
        try ensureAttachmentReferenceIndexVerified()
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
        try unreferencedBlobIDsFromVerifiedIndex(
            candidateIDs,
            excluding: recordIDs,
            shouldContinue: shouldContinue
        )
    }

    /// Returns only already-proven orphan candidates. Unknown legacy references
    /// suppress physical deletion without blocking logical retention or journal
    /// replay; a later successful backfill can make cleanup eligible.
    public func unreferencedBlobIDsWithoutBackfill(
        _ candidateIDs: Set<String>,
        excluding recordIDs: Set<RecordID> = [],
        shouldContinue: () -> Bool = { true }
    ) throws -> Set<String> {
        guard shouldContinue() else { throw CancellationError() }
        guard !candidateIDs.isEmpty else { return [] }
        return try unreferencedBlobIDsFromVerifiedIndex(
            candidateIDs,
            excluding: recordIDs,
            shouldContinue: shouldContinue,
            backfill: false
        )
    }

    // Returns every external Blob referenced by a record, including the
    // legacy primary image payload and oversized representation rows. Callers
    // use this before deleting the parent row so all of the record's files can
    // be reclaimed immediately instead of waiting for startup reconciliation.

    public func blobIDs(
        for id: RecordID,
        allowUnprovenLegacyReferences: Bool = false
    ) throws -> Set<String> {
        try database.queue.write { connection in
            var hasUnprovenLegacyReferences = false
            do {
                try ensureAttachmentReferenceIndexVerified(for: id, on: connection)
            } catch MacClippyStoreError.unprovenLegacyAttachmentReferences {
                guard allowUnprovenLegacyReferences else { throw MacClippyStoreError.invalidStoredRecord }
                hasUnprovenLegacyReferences = true
            }
            var ids = Set<String>()
            if let primary = try String.fetchOne(
                connection,
                sql: "SELECT primary_blob_id FROM clipboard_records WHERE id = ?",
                arguments: [id.rawValue]
            ) {
                ids.insert(primary)
            }
            let representationIDs = try Row.fetchAll(
                connection,
                sql: """
                    SELECT blob_id FROM clipboard_representations
                    WHERE record_id = ? AND payload_state = 'spilled' AND blob_id IS NOT NULL
                    """,
                arguments: [id.rawValue]
            ).compactMap { $0["blob_id"] as String? }
            ids.formUnion(representationIDs)
            if hasUnprovenLegacyReferences {
                if let primary = try legacyPrimaryBlobID(for: id, on: connection) {
                    ids.insert(primary)
                }
            }
            return ids
        }
    }

    private func legacyPrimaryBlobID(for id: RecordID, on connection: Database) throws -> String? {
        guard let row = try Row.fetchOne(
            connection,
            sql: "SELECT envelope, content_kind FROM clipboard_records WHERE id = ?",
            arguments: [id.rawValue]
        ), let envelope: Data = row["envelope"],
           let contentKind: String = row["content_kind"],
           let expectedKind = MacClippyContentKind(rawValue: contentKind) else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        let body = try MacClippyClipboardRecordEnvelopeCodec.decode(
            MacClippyCipher.open(MacClippyEnvelope(combined: envelope), with: key)
        )
        guard !body.requiresRepresentationRoster,
              body.record.contentKind == expectedKind else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        guard let primary = body.record.imageBlobID else { return nil }
        guard MacClippyBlobStore.isSafeIdentifier(primary) else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        return primary
    }

    /// Persists a deletion intent before callers touch the other stores. A
    /// journal with no blob rows is still retained in the operations table,
    /// so records without external payloads are recoverable too.

    /// Reads representation state and sizes without decrypting inline payloads.
    /// Details and diagnostics should use this projection; payload decryption
    /// remains reserved for copy/paste, preview and export.
    public func representationMetadata(for id: RecordID) throws -> [MacClippyClipboardRepresentationMetadata] {
        try database.queue.read { connection in
            let rows = try Row.fetchAll(
                connection,
                sql: """
                    SELECT item_index, uti, payload, blob_id, payload_state
                    FROM clipboard_representations WHERE record_id = ? ORDER BY sort_order ASC
                """,
                arguments: [id.rawValue]
            )
            return try rows.map { row in
                let itemIndex: Int = row["item_index"]
                let uti: String = row["uti"]
                let payload: Data? = row["payload"]
                let blobID: String? = row["blob_id"]
                guard itemIndex >= 0,
                      !uti.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
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
                    itemIndex: itemIndex,
                    uti: uti,
                    payloadState: state,
                    inlineByteCount: payload?.count ?? 0,
                    blobID: blobID
                )
            }
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
                sql: """
                    SELECT item_index, uti, payload, blob_id, payload_state
                    FROM clipboard_representations WHERE record_id = ? ORDER BY sort_order ASC
                """,
                arguments: [id.rawValue]
            )
            return try rows.map { row in
                guard let itemIndex: Int = row["item_index"],
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

}
