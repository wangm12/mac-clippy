import CryptoKit
import Foundation
import GRDB

extension MacClippyClipboardStore {
    func markAttachmentReferenceIndexVerified(for id: RecordID, on connection: Database) throws {
        try connection.execute(
            sql: "UPDATE clipboard_records SET blob_references_verified = 1 WHERE id = ?",
            arguments: [id.rawValue]
        )
    }

    func ensureAttachmentReferenceIndexVerified(
        for id: RecordID,
        on connection: Database
    ) throws {
        guard let verified = try Int.fetchOne(
            connection,
            sql: "SELECT blob_references_verified FROM clipboard_records WHERE id = ?",
            arguments: [id.rawValue]
        ) else {
            throw MacClippyStoreError.recordNotFound
        }
        guard verified == 0 || verified == 1 else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        if verified == 0 {
            try authenticateAndVerifyAttachmentReferences(for: id, on: connection)
        }
    }

    /// Authenticates legacy rows in bounded write transactions. The verified
    /// marker is invalidated by schema triggers whenever an envelope or
    /// representation row changes, including direct SQL repair/test writes.
    func ensureAttachmentReferenceIndexVerified(
        shouldContinue: () -> Bool = { true }
    ) throws {
        while true {
            guard shouldContinue() else { throw CancellationError() }
            let page = try database.queue.read { connection in
                try String.fetchAll(
                    connection,
                    sql: """
                        SELECT id FROM clipboard_records
                        WHERE blob_references_verified != 1
                        ORDER BY id
                        LIMIT ?
                    """,
                    arguments: [MacClippyBlobReferenceIndexPolicy.pageSize]
                )
            }
            guard !page.isEmpty else { return }

            try database.queue.write { connection in
                for rawID in page {
                    guard shouldContinue() else { throw CancellationError() }
                    guard let id = RecordID(rawValue: rawID) else {
                        throw MacClippyStoreError.invalidStoredRecord
                    }
                    try authenticateAndVerifyAttachmentReferences(for: id, on: connection)
                }
            }
        }
    }

    /// Authenticates legacy body and representation references in bounded
    /// transactions. Runtime callers should prepare this index before taking
    /// their global storage commit fence; destructive lookups still verify
    /// that no row became unverified before returning candidates.
    public func authenticateOwnedBlobReferenceIndex(
        shouldContinue: () -> Bool = { true }
    ) throws {
        try ensureAttachmentReferenceIndexVerified(shouldContinue: shouldContinue)
    }

    /// Verifies every row that can be proven, while leaving AEAD-valid legacy
    /// spill references unverified so retention can delete their records and
    /// safely defer physical BlobStore cleanup.
    public func authenticateOwnedBlobReferenceIndexForRetention(
        shouldContinue: () -> Bool = { true }
    ) throws {
        var lastID: String?
        while true {
            guard shouldContinue() else { throw CancellationError() }
            let page = try database.queue.read { connection in
                var sql = "SELECT id FROM clipboard_records WHERE blob_references_verified != 1"
                var arguments: [Any] = []
                if let lastID {
                    sql += " AND id > ?"
                    arguments.append(lastID)
                }
                sql += " ORDER BY id LIMIT ?"
                arguments.append(MacClippyBlobReferenceIndexPolicy.pageSize)
                guard let statementArguments = StatementArguments(arguments) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return try String.fetchAll(connection, sql: sql, arguments: statementArguments)
            }
            guard let pageLastID = page.last else { return }
            try database.queue.write { connection in
                for rawID in page {
                    guard shouldContinue(), let id = RecordID(rawValue: rawID) else {
                        throw shouldContinue() ? MacClippyStoreError.invalidStoredRecord : CancellationError()
                    }
                    do {
                        try authenticateAndVerifyAttachmentReferences(for: id, on: connection)
                    } catch MacClippyStoreError.unprovenLegacyAttachmentReferences {
                        continue
                    }
                }
            }
            lastID = pageLastID
        }
    }

    /// Streams the normalized body-image and spilled-representation indexes.
    /// Callbacks receive IDs only after every legacy/unverified row has been
    /// authenticated; no history envelope is decrypted on an already-verified
    /// maintenance pass.
    public func forEachReferencedBlobID(
        shouldContinue: () -> Bool = { true },
        _ body: (String) throws -> Void
    ) throws {
        try ensureAttachmentReferenceIndexVerified(shouldContinue: shouldContinue)
        try forEachDistinctBlobID(
            sqlColumn: "primary_blob_id",
            table: "clipboard_records",
            shouldContinue: shouldContinue,
            body
        )
        try forEachDistinctBlobID(
            sqlColumn: "blob_id",
            table: "clipboard_representations",
            shouldContinue: shouldContinue,
            body
        )
    }

    func forEachReferencedBlobReference(
        excluding recordIDs: Set<RecordID>,
        shouldContinue: () -> Bool = { true },
        _ body: (String) throws -> Void
    ) throws {
        try ensureAttachmentReferenceIndexVerified(shouldContinue: shouldContinue)
        try forEachBlobReference(
            query: MacClippyBlobReferenceQuery(
                table: "clipboard_records",
                blobColumn: "primary_blob_id",
                ownerColumn: "id",
                utiColumn: nil
            ),
            excluding: recordIDs,
            shouldContinue: shouldContinue,
            body
        )
        try forEachBlobReference(
            query: MacClippyBlobReferenceQuery(
                table: "clipboard_representations",
                blobColumn: "blob_id",
                ownerColumn: "record_id",
                utiColumn: "uti"
            ),
            excluding: recordIDs,
            shouldContinue: shouldContinue,
            body
        )
    }

    func hasReferencedBlob(
        _ blobID: String,
        excluding recordIDs: Set<RecordID> = [],
        shouldContinue: () -> Bool = { true }
    ) throws -> Bool {
        try unreferencedBlobIDsFromVerifiedIndex(
            [blobID],
            excluding: recordIDs,
            shouldContinue: shouldContinue
        ).isEmpty
    }

    func referencedBlobIDsFromVerifiedIndex(
        excluding recordIDs: Set<RecordID> = [],
        shouldContinue: () -> Bool = { true }
    ) throws -> Set<String> {
        var result = Set<String>()
        try forEachReferencedBlobReference(excluding: recordIDs, shouldContinue: shouldContinue) {
            result.insert($0)
        }
        return result
    }

    func unreferencedBlobIDsFromVerifiedIndex(
        _ candidateIDs: Set<String>,
        excluding recordIDs: Set<RecordID> = [],
        shouldContinue: () -> Bool = { true },
        backfill: Bool = true
    ) throws -> Set<String> {
        guard shouldContinue() else { throw CancellationError() }
        guard !candidateIDs.isEmpty else { return [] }
        guard shouldContinue() else { throw CancellationError() }
        if backfill {
            try ensureAttachmentReferenceIndexVerified(shouldContinue: shouldContinue)
        }
        return try database.queue.write { connection in
            // Never start an unbounded legacy backfill while the caller is in
            // its short deletion/retention commit fence. If another writer
            // invalidated the marker after preflight, fail closed and let the
            // outer maintenance operation retry outside its fence.
            guard try Row.fetchOne(
                connection,
                sql: "SELECT 1 FROM clipboard_records WHERE blob_references_verified != 1 LIMIT 1"
            ) == nil else {
                if !backfill { return [] }
                throw MacClippyStoreError.invalidStoredRecord
            }

            var unreferenced = candidateIDs
            let candidateList = Array(candidateIDs)
            for start in stride(from: 0, to: candidateList.count, by: Self.sqliteIDBatchSize) {
                guard shouldContinue() else { throw CancellationError() }
                let batch = Array(candidateList[start ..< min(start + Self.sqliteIDBatchSize, candidateList.count)])
                try removeReferencedCandidates(
                    MacClippyBlobCandidateQuery(
                        candidates: batch,
                        table: "clipboard_records",
                        blobColumn: "primary_blob_id",
                        ownerColumn: "id",
                        excluding: recordIDs
                    ),
                    from: &unreferenced,
                    shouldContinue: shouldContinue,
                    on: connection
                )
                try removeReferencedCandidates(
                    MacClippyBlobCandidateQuery(
                        candidates: batch,
                        table: "clipboard_representations",
                        blobColumn: "blob_id",
                        ownerColumn: "record_id",
                        excluding: recordIDs
                    ),
                    from: &unreferenced,
                    shouldContinue: shouldContinue,
                    on: connection
                )
            }
            return unreferenced
        }
    }

    func authenticateAndVerifyAttachmentReferences(
        for id: RecordID,
        on connection: Database
    ) throws {
        guard let row = try Row.fetchOne(
            connection,
            sql: "SELECT envelope, content_kind, representation_refs_auth FROM clipboard_records WHERE id = ?",
            arguments: [id.rawValue]
        ) else {
            return
        }
        guard let envelope: Data = row["envelope"],
              let contentKind: String = row["content_kind"],
              let persistedKind = MacClippyContentKind(rawValue: contentKind) else {
            throw MacClippyStoreError.invalidStoredRecord
        }

        let decodedBody = try authenticatedRecordBody(envelope, expectedContentKind: persistedKind)
        let record = decodedBody.record
        guard record.imageBlobID.map(MacClippyBlobStore.isSafeIdentifier) ?? true else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        try authenticateRepresentationRoster(
            row["representation_refs_auth"],
            for: id,
            decodedBody: decodedBody,
            on: connection
        )

        if !decodedBody.requiresRepresentationRoster {
            let currentEnvelope = try MacClippyCipher.seal(try encodedRecordData(record), with: key)
            try connection.execute(
                sql: "UPDATE clipboard_records SET envelope = ? WHERE id = ?",
                arguments: [currentEnvelope.combined, id.rawValue]
            )
        }

        // The envelope, body discriminator and all representation envelopes
        // have now authenticated. Updating the denormalized lookup column is
        // followed by a separate trusted-marker write because the SQL trigger
        // intentionally invalidates that marker on primary_blob_id changes.
        try connection.execute(
            sql: "UPDATE clipboard_records SET primary_blob_id = ? WHERE id = ?",
            arguments: [record.imageBlobID, id.rawValue]
        )
        try connection.execute(
            sql: "UPDATE clipboard_records SET blob_references_verified = 1 WHERE id = ?",
            arguments: [id.rawValue]
        )
    }

    private func authenticateRepresentationRoster(
        _ envelope: Data?,
        for id: RecordID,
        decodedBody: MacClippyDecodedClipboardRecordEnvelope,
        on connection: Database
    ) throws {
        if let envelope {
            let authenticatedRoster = try MacClippyRepresentationRosterCodec.open(envelope, key: key)
            // Schema 012 adds itemIndex to the rows, but existing authenticated
            // v1 rosters remain valid when every row belongs to item zero. Build
            // the current view using the authenticated roster's version so
            // maintenance applies the same compatibility rule as normal reads.
            let currentRoster = try authenticatedRepresentationRoster(
                for: id,
                on: connection,
                version: authenticatedRoster.version
            )
            guard authenticatedRoster == currentRoster else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return
        }

        let currentRoster = try authenticatedRepresentationRoster(for: id, on: connection)
        // Legacy spilled references have no trusted source tying their
        // plaintext blob IDs to this record. Retain them until the full
        // representation set is explicitly replaced through the API.
        guard !decodedBody.requiresRepresentationRoster else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        guard !currentRoster.representations.contains(where: { $0.blobID != nil }) else {
            throw MacClippyStoreError.unprovenLegacyAttachmentReferences
        }
        try persistAuthenticatedRepresentationRoster(currentRoster, on: connection)
    }

    private func authenticatedRecordBody(
        _ envelope: Data,
        expectedContentKind: MacClippyContentKind
    ) throws -> MacClippyDecodedClipboardRecordEnvelope {
        noteRecordEnvelopeDecrypt()
        let decodedBody = try MacClippyClipboardRecordEnvelopeCodec.decode(
            MacClippyCipher.open(MacClippyEnvelope(combined: envelope), with: key)
        )
        guard decodedBody.record.contentKind == expectedContentKind else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        return decodedBody
    }

    private func authenticatedRepresentationRoster(
        for id: RecordID,
        on connection: Database,
        version: Int? = nil
    ) throws -> MacClippyRepresentationRoster {
        try MacClippyRepresentationRosterCodec.current(
            recordID: id.rawValue,
            on: connection,
            maxRepresentations: inputLimits.maxRepresentationsPerRecord,
            version: version,
            validatePayload: { [self] payload in
                noteRepresentationPayloadDecrypt()
                do {
                    _ = try MacClippyCipher.open(MacClippyEnvelope(combined: payload), with: key)
                } catch {
                    throw MacClippyStoreError.invalidStoredRecord
                }
            }
        )
    }

    func persistAuthenticatedRepresentationRoster(
        for id: RecordID,
        on connection: Database
    ) throws {
        try persistAuthenticatedRepresentationRoster(
            authenticatedRepresentationRoster(for: id, on: connection),
            on: connection
        )
    }

    private func persistAuthenticatedRepresentationRoster(
        _ roster: MacClippyRepresentationRoster,
        on connection: Database
    ) throws {
        let envelope = try MacClippyRepresentationRosterCodec.seal(roster, key: key)
        try connection.execute(
            sql: "UPDATE clipboard_records SET representation_refs_auth = ? WHERE id = ?",
            arguments: [envelope, roster.recordID]
        )
    }

}
