import CryptoKit
import Foundation
import GRDB

struct MacClippyPreparedRepresentation {
    let itemIndex: Int
    let sortOrder: Int
    let uti: String
    let payload: Data?
    let blobID: String?
    let state: MacClippyClipboardRepresentationPayloadState
}

public struct MacClippyClipboardPlaybackSnapshot: Sendable {
    public let record: ClipboardRecord
    public let representations: [MacClippyClipboardRepresentation]

    public init(record: ClipboardRecord, representations: [MacClippyClipboardRepresentation]) {
        self.record = record
        self.representations = representations
    }
}

extension MacClippyClipboardStore {
    public func representations(for id: RecordID) throws -> [MacClippyClipboardRepresentation] {
        do {
            return try playbackSnapshot(for: id).representations
        } catch MacClippyStoreError.recordNotFound {
            return []
        }
    }

    /// Reads and authenticates the body, roster, and representation rows from
    /// one SQLite snapshot before they are used for replay or mutation.
    public func playbackSnapshot(for id: RecordID) throws -> MacClippyClipboardPlaybackSnapshot {
        try playbackSnapshot(for: id, matchingRepresentationUTIs: nil)
    }

    /// Reads the authenticated body and roster, then materializes only the
    /// requested representation payload rows. The roster is still validated
    /// in full so filtering payload reads cannot hide a rewritten or missing
    /// representation row.
    public func playbackSnapshot(
        for id: RecordID,
        matchingRepresentationUTIs utis: Set<String>,
        matchingAdditionalRepresentationUTIs shouldIncludeAdditionalUTI: (@Sendable (String) -> Bool)? = nil
    ) throws -> MacClippyClipboardPlaybackSnapshot {
        try playbackSnapshot(
            for: id,
            matchingRepresentationUTIs: Optional(utis),
            matchingAdditionalRepresentationUTIs: shouldIncludeAdditionalUTI
        )
    }

    private func playbackSnapshot(
        for id: RecordID,
        matchingRepresentationUTIs requestedUTIs: Set<String>?,
        matchingAdditionalRepresentationUTIs shouldIncludeAdditionalUTI: (@Sendable (String) -> Bool)? = nil
    ) throws -> MacClippyClipboardPlaybackSnapshot {
        try database.queue.read { connection in
            guard let row = try Row.fetchOne(
                connection,
                sql: """
                    SELECT envelope, content_kind, representation_refs_auth
                    FROM clipboard_records WHERE id = ?
                    """,
                arguments: [id.rawValue]
            ), let envelope: Data = row["envelope"],
               let rawContentKind: String = row["content_kind"],
               let expectedContentKind = MacClippyContentKind(rawValue: rawContentKind) else {
                throw MacClippyStoreError.recordNotFound
            }
            noteRecordEnvelopeDecrypt()
            let decoded = try MacClippyClipboardRecordEnvelopeCodec.decode(
                MacClippyCipher.open(MacClippyEnvelope(combined: envelope), with: key)
            )
            guard decoded.record.contentKind == expectedContentKind else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            let rosterEnvelope: Data? = row["representation_refs_auth"]
            if decoded.requiresRepresentationRoster || rosterEnvelope != nil {
                try MacClippyRepresentationRosterCodec.validate(
                    recordID: id.rawValue,
                    envelope: rosterEnvelope,
                    on: connection,
                    key: key,
                    maxRepresentations: inputLimits.maxRepresentationsPerRecord
                )
            }
            let representations = try playbackRepresentations(
                for: id, on: connection, requestedUTIs: requestedUTIs,
                hasAuthenticatedRoster: decoded.requiresRepresentationRoster || rosterEnvelope != nil,
                shouldIncludeAdditionalUTI: shouldIncludeAdditionalUTI
            )
            return MacClippyClipboardPlaybackSnapshot(
                record: decoded.record,
                representations: representations
            )
        }
    }

    private func playbackRepresentations(
        for id: RecordID,
        on connection: Database,
        requestedUTIs: Set<String>?,
        hasAuthenticatedRoster: Bool,
        shouldIncludeAdditionalUTI: (@Sendable (String) -> Bool)?
    ) throws -> [MacClippyClipboardRepresentation] {
        guard var selectedUTIs = requestedUTIs else {
            // Full reads also validate legacy rows without an authenticated roster.
            return try representationRows(for: id, on: connection)
        }
        if !hasAuthenticatedRoster {
            // Filtered reads must check the entire legacy row shape without
            // decrypting payload bytes belonging to unrelated UTIs.
            try validateLegacyRepresentationRows(for: id, on: connection)
        }
        if let shouldIncludeAdditionalUTI {
            let utiRows = try Row.fetchAll(
                connection,
                sql: "SELECT DISTINCT uti FROM clipboard_representations WHERE record_id = ?",
                arguments: [id.rawValue]
            )
            for row in utiRows {
                guard let uti: String = row["uti"] else { throw MacClippyStoreError.invalidStoredRecord }
                if shouldIncludeAdditionalUTI(uti) { selectedUTIs.insert(uti) }
            }
        }
        return try representationRows(for: id, matchingUTIs: selectedUTIs, on: connection)
    }

    private func representationRows(
        for id: RecordID,
        on connection: Database
    ) throws -> [MacClippyClipboardRepresentation] {
        let rows = try Row.fetchAll(
            connection,
            sql: """
                SELECT item_index, uti, payload, blob_id, payload_state
                FROM clipboard_representations
                WHERE record_id = ?
                ORDER BY sort_order ASC, item_index ASC, uti ASC
                """,
            arguments: [id.rawValue]
        )
        return try rows.map(readRepresentation)
    }

    private func validateLegacyRepresentationRows(for id: RecordID, on connection: Database) throws {
        let rows = try Row.fetchCursor(
            connection,
            sql: """
                SELECT payload IS NOT NULL AS has_payload, blob_id, payload_state
                FROM clipboard_representations WHERE record_id = ?
                """,
            arguments: [id.rawValue]
        )
        while let row = try rows.next() {
            guard let stateString: String = row["payload_state"],
                  let state = MacClippyClipboardRepresentationPayloadState(rawValue: stateString) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            let hasPayload: Int = row["has_payload"]
            let blobID: String? = row["blob_id"]
            switch state {
            case .present:
                guard hasPayload != 0, blobID == nil else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
            case .spilled:
                guard hasPayload == 0, blobID != nil else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
            case .unavailable, .oversized:
                guard hasPayload == 0, blobID == nil else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
            }
        }
    }

    private func representationRows(
        for id: RecordID,
        matchingUTIs utis: Set<String>,
        on connection: Database
    ) throws -> [MacClippyClipboardRepresentation] {
        let orderedUTIs = utis.sorted()
        guard !orderedUTIs.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: orderedUTIs.count).joined(separator: ",")
        let rows = try Row.fetchAll(
            connection,
            sql: """
                SELECT item_index, uti, payload, blob_id, payload_state
                FROM clipboard_representations
                WHERE record_id = ? AND uti IN (\(placeholders))
                ORDER BY sort_order ASC, item_index ASC, uti ASC
                """,
            arguments: StatementArguments([id.rawValue] + orderedUTIs)
        )
        return try rows.map(readRepresentation)
    }

    private func readRepresentation(from row: Row) throws -> MacClippyClipboardRepresentation {
        let itemIndex: Int = row["item_index"]
        let uti: String = row["uti"]
        let blobID: String? = row["blob_id"]
        let payload: Data? = row["payload"]
        let stateString: String? = row["payload_state"]
        guard let stateString,
              let state = MacClippyClipboardRepresentationPayloadState(rawValue: stateString) else {
            throw MacClippyStoreError.invalidStoredRecord
        }

        switch state {
        case .unavailable, .oversized:
            guard payload == nil, blobID == nil else { throw MacClippyStoreError.invalidStoredRecord }
            return MacClippyClipboardRepresentation(
                itemIndex: itemIndex,
                uti: uti,
                payloadBytes: nil,
                blobID: nil,
                payloadState: state
            )
        case .spilled:
            guard payload == nil, blobID != nil else { throw MacClippyStoreError.invalidStoredRecord }
            return MacClippyClipboardRepresentation(
                itemIndex: itemIndex,
                uti: uti,
                payloadBytes: nil,
                blobID: blobID,
                payloadState: .spilled
            )
        case .present:
            guard let payload, blobID == nil else { throw MacClippyStoreError.invalidStoredRecord }
            return MacClippyClipboardRepresentation(
                itemIndex: itemIndex,
                uti: uti,
                payloadBytes: try decryptedRepresentationPayload(payload),
                blobID: nil,
                payloadState: .present
            )
        }
    }

    private func decryptedRepresentationPayload(_ payload: Data) throws -> Data {
        do {
            noteRepresentationPayloadDecrypt()
            return try MacClippyCipher.open(MacClippyEnvelope(combined: payload), with: key)
        } catch let error as MacClippyCipherError {
            // Authentication failures can mean the device key is wrong or
            // unavailable; do not relabel them as a single corrupt record.
            throw error
        } catch {
            throw MacClippyStoreError.invalidStoredRecord
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
        try validateRepresentationLimits(representations)
        let preparedRows = try preparedRepresentationRows(from: representations)
        try database.queue.write { connection in
            guard try Row.fetchOne(
                connection,
                sql: "SELECT 1 FROM clipboard_records WHERE id = ?",
                arguments: [id.rawValue]
            ) != nil else {
                throw MacClippyStoreError.recordNotFound
            }
            try writeRepresentationRows(preparedRows, for: id, on: connection)
            try persistAuthenticatedRepresentationRoster(for: id, on: connection)
            try authenticateAndVerifyAttachmentReferences(for: id, on: connection)
        }
    }

    func preparedRepresentationRows(
        from representations: [MacClippyClipboardRepresentation]
    ) throws -> [MacClippyPreparedRepresentation] {
        var seenPairs = Set<String>()
        return try representations.enumerated().map { index, representation in
            guard !representation.uti.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  representation.itemIndex >= 0,
                  seenPairs.insert("\(representation.itemIndex)\u{0}\(representation.uti)").inserted else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            switch representation.payloadState {
            case .present:
                guard let payloadBytes = representation.payloadBytes,
                      representation.blobID == nil else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return MacClippyPreparedRepresentation(
                    itemIndex: representation.itemIndex,
                    sortOrder: index,
                    uti: representation.uti,
                    payload: try MacClippyCipher.seal(payloadBytes, with: key).combined,
                    blobID: nil,
                    state: .present
                )
            case .spilled:
                guard representation.payloadBytes == nil,
                      let blobID = representation.blobID,
                      !blobID.isEmpty else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return MacClippyPreparedRepresentation(
                    itemIndex: representation.itemIndex,
                    sortOrder: index,
                    uti: representation.uti,
                    payload: nil,
                    blobID: blobID,
                    state: .spilled
                )
            case .unavailable, .oversized:
                guard representation.payloadBytes == nil, representation.blobID == nil else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return MacClippyPreparedRepresentation(
                    itemIndex: representation.itemIndex,
                    sortOrder: index,
                    uti: representation.uti,
                    payload: nil,
                    blobID: nil,
                    state: representation.payloadState
                )
            }
        }
    }

    func writeRepresentationRows(
        _ preparedRows: [MacClippyPreparedRepresentation],
        for id: RecordID,
        on connection: Database
    ) throws {
        try connection.execute(
            sql: "DELETE FROM clipboard_representations WHERE record_id = ?",
            arguments: [id.rawValue]
        )
        for row in preparedRows {
            try connection.execute(
                sql: """
                    INSERT INTO clipboard_representations
                        (record_id, item_index, sort_order, uti, payload, blob_id, payload_state)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    id.rawValue,
                    row.itemIndex,
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
