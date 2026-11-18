import CryptoKit
import Foundation
import GRDB

extension MacClippyClipboardStore {
    private struct CaptureMetadata {
        let id: RecordID
        let milliseconds: Int64
        let sourceAppBundleID: String?
        let sourceAppDisplayName: String?
        let detectedTypeJSON: String?
        let contentHash: String?
    }

    private struct PreparedRepresentationRow {
        let itemIndex: Int
        let sortOrder: Int
        let uti: String
        let payload: Data?
        let blobID: String?
        let state: MacClippyClipboardRepresentationPayloadState
    }

    private struct ClipboardRowInsert {
        let record: ClipboardRecord
        let envelope: Data
        let metadata: CaptureMetadata
        let lamport: Int64
        let includesContentHash: Bool
    }

    @discardableResult
    public func append(
        _ record: ClipboardRecord,
        sourceAppBundleID: String? = nil,
        sourceAppDisplayName: String? = nil,
        detectedTypeJSON: String? = nil,
        now: Date = Date()
    ) throws -> ClipboardItemMeta {
        let metadata = captureMetadata(
            sourceAppBundleID: sourceAppBundleID,
            sourceAppDisplayName: sourceAppDisplayName,
            detectedTypeJSON: detectedTypeJSON,
            contentHash: nil,
            now: now
        )
        let lamport = try persistCapture(record, metadata: metadata, representations: nil)
        return captureMeta(record, metadata: metadata, lamport: lamport, now: now)
    }

    /// Persists the encrypted primary body and every advertised pasteboard
    /// representation in one transaction. Spilled files are compensated when
    /// row preparation or the SQLite transaction fails.
    @discardableResult
    public func append(
        _ record: ClipboardRecord,
        representations: [MacClippyClipboardRepresentation],
        sourceAppBundleID: String? = nil,
        sourceAppDisplayName: String? = nil,
        detectedTypeJSON: String? = nil,
        contentHash: String? = nil,
        spillPayload: ((Data) throws -> String)? = nil,
        deleteSpilledPayload: ((String) -> Void)? = nil,
        now: Date = Date()
    ) throws -> ClipboardItemMeta {
        try validateRepresentationLimits(representations)
        let metadata = captureMetadata(
            sourceAppBundleID: sourceAppBundleID,
            sourceAppDisplayName: sourceAppDisplayName,
            detectedTypeJSON: detectedTypeJSON,
            contentHash: contentHash,
            now: now
        )
        let prepared = try prepareRepresentationRows(
            representations,
            spillPayload: spillPayload,
            deleteSpilledPayload: deleteSpilledPayload
        )
        let lamport: UInt64
        do {
            lamport = try persistCapture(record, metadata: metadata, representations: prepared.rows)
        } catch {
            for blobID in prepared.spilledBlobIDs { deleteSpilledPayload?(blobID) }
            throw error
        }
        return captureMeta(record, metadata: metadata, lamport: lamport, now: now)
    }

    private func captureMetadata(
        sourceAppBundleID: String?,
        sourceAppDisplayName: String?,
        detectedTypeJSON: String?,
        contentHash: String?,
        now: Date
    ) -> CaptureMetadata {
        CaptureMetadata(
            id: RecordID.generate(),
            milliseconds: Self.milliseconds(now),
            sourceAppBundleID: sourceAppBundleID,
            sourceAppDisplayName: sourceAppDisplayName,
            detectedTypeJSON: detectedTypeJSON,
            contentHash: contentHash
        )
    }

    private func captureMeta(
        _ record: ClipboardRecord,
        metadata: CaptureMetadata,
        lamport: UInt64,
        now: Date
    ) -> ClipboardItemMeta {
        ClipboardItemMeta(
            id: metadata.id,
            created: now,
            modified: now,
            deviceID: deviceID,
            lamport: lamport,
            contentKind: record.contentKind,
            preview: Self.preview(for: record),
            sourceAppBundleID: metadata.sourceAppBundleID,
            sourceAppDisplayName: metadata.sourceAppDisplayName,
            detectedTypeJSON: metadata.detectedTypeJSON
        )
    }

    private func persistCapture(
        _ record: ClipboardRecord,
        metadata: CaptureMetadata,
        representations: [PreparedRepresentationRow]?
    ) throws -> UInt64 {
        let envelope = try MacClippyCipher.seal(try encodedRecordData(record), with: key)
        return try database.queue.write { connection in
            let current = try Int64.fetchOne(
                connection,
                sql: "SELECT value FROM macclippy_lamport_clock WHERE scope = 'clipboard'"
            ) ?? 0
            let next = current == Int64.max ? current : current + 1
            try connection.execute(
                sql: "UPDATE macclippy_lamport_clock SET value = ? WHERE scope = 'clipboard'",
                arguments: [next]
            )
            try insertClipboardRow(
                ClipboardRowInsert(
                    record: record,
                    envelope: envelope.combined,
                    metadata: metadata,
                    lamport: next,
                    includesContentHash: representations != nil
                ),
                on: connection
            )
            for representation in representations ?? [] {
                try insert(representation, for: metadata.id, on: connection)
            }
            try persistAuthenticatedRepresentationRoster(for: metadata.id, on: connection)
            try markAttachmentReferenceIndexVerified(for: metadata.id, on: connection)
            return UInt64(next)
        }
    }

    private func insertClipboardRow(_ row: ClipboardRowInsert, on connection: Database) throws {
        let columns = row.includesContentHash
            ? "content_hash, primary_blob_id"
            : "primary_blob_id"
        let values = row.includesContentHash
            ? "?, ?"
            : "?"
        let metadata = row.metadata
        var arguments: [DatabaseValueConvertible?] = [
            metadata.id.rawValue,
            metadata.milliseconds,
            metadata.milliseconds,
            deviceID.rawValue,
            row.lamport,
            RecordKind.clipboardItem.rawValue,
            row.record.contentKind.rawValue,
            Self.preview(for: row.record),
            metadata.sourceAppBundleID,
            metadata.sourceAppDisplayName,
            metadata.detectedTypeJSON,
            row.envelope
        ]
        if row.includesContentHash { arguments.append(metadata.contentHash) }
        arguments.append(row.record.imageBlobID)
        try connection.execute(
            sql: """
                INSERT INTO clipboard_records
                    (id, created, modified, device_id, lamport, kind, content_kind, preview,
                     source_app, source_app_name, detected_type, envelope, \(columns))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, \(values))
                """,
            arguments: StatementArguments(arguments)
        )
    }

    private func insert(
        _ row: PreparedRepresentationRow,
        for id: RecordID,
        on connection: Database
    ) throws {
        try connection.execute(
            sql: """
                INSERT OR REPLACE INTO clipboard_representations
                    (record_id, item_index, sort_order, uti, payload, blob_id, payload_state)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id.rawValue, row.itemIndex, row.sortOrder, row.uti, row.payload, row.blobID, row.state.rawValue]
        )
    }

    private func prepareRepresentationRows(
        _ representations: [MacClippyClipboardRepresentation],
        spillPayload: ((Data) throws -> String)?,
        deleteSpilledPayload: ((String) -> Void)?
    ) throws -> (rows: [PreparedRepresentationRow], spilledBlobIDs: [String]) {
        var spilledBlobIDs: [String] = []
        do {
            let rows = try representations.enumerated().map { index, representation in
                try prepareRepresentationRow(
                    representation,
                    atIndex: index,
                    spillPayload: spillPayload,
                    spilledBlobIDs: &spilledBlobIDs
                )
            }
            return (rows, spilledBlobIDs)
        } catch {
            for blobID in spilledBlobIDs { deleteSpilledPayload?(blobID) }
            throw error
        }
    }

    private func prepareRepresentationRow(
        _ representation: MacClippyClipboardRepresentation,
        atIndex index: Int,
        spillPayload: ((Data) throws -> String)?,
        spilledBlobIDs: inout [String]
    ) throws -> PreparedRepresentationRow {
        switch representation.payloadState {
        case .unavailable, .oversized:
            guard representation.payloadBytes == nil, representation.blobID == nil else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return PreparedRepresentationRow(
                itemIndex: representation.itemIndex,
                sortOrder: index,
                uti: representation.uti,
                payload: nil,
                blobID: nil,
                state: representation.payloadState
            )
        case .spilled:
            guard representation.payloadBytes == nil,
                  let blobID = representation.blobID,
                  MacClippyBlobStore.isSafeIdentifier(blobID) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return PreparedRepresentationRow(
                itemIndex: representation.itemIndex,
                sortOrder: index,
                uti: representation.uti,
                payload: nil,
                blobID: blobID,
                state: .spilled
            )
        case .present:
            guard representation.blobID == nil else { throw MacClippyStoreError.invalidStoredRecord }
            return try prepareInlineRepresentation(
                representation,
                atIndex: index,
                spillPayload: spillPayload,
                spilledBlobIDs: &spilledBlobIDs
            )
        }
    }

    private func prepareInlineRepresentation(
        _ representation: MacClippyClipboardRepresentation,
        atIndex index: Int,
        spillPayload: ((Data) throws -> String)?,
        spilledBlobIDs: inout [String]
    ) throws -> PreparedRepresentationRow {
        guard let payload = representation.payloadBytes else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        guard payload.count <= inputLimits.maxRepresentationBytes else {
            throw MacClippyStoreError.inputTooLarge
        }
        if payload.count > MacClippyClipboardRepresentationLimits.inlineByteCeiling,
           let spillPayload {
            let blobID = try spillPayload(payload)
            spilledBlobIDs.append(blobID)
            return PreparedRepresentationRow(
                itemIndex: representation.itemIndex,
                sortOrder: index,
                uti: representation.uti,
                payload: nil,
                blobID: blobID,
                state: .spilled
            )
        }
        let sealed = try MacClippyCipher.seal(payload, with: key)
        return PreparedRepresentationRow(
            itemIndex: representation.itemIndex,
            sortOrder: index,
            uti: representation.uti,
            payload: sealed.combined,
            blobID: nil,
            state: .present
        )
    }
}
