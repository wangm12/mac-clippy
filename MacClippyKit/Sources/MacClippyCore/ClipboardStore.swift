import CryptoKit
import Foundation
import GRDB

public enum MacClippyStoreError: Error {
    case recordNotFound
    case invalidStoredRecord
    case inputTooLarge
}

public struct MacClippyClipboardMetadataFilter: Sendable {
    public var contentKind: MacClippyContentKind?
    public var sourceAppContains: [String]
    public var labelContains: [String]
    public var requiresLabel: Bool
    public var requiresOCR: Bool
    public var modifiedBefore: [Date]
    public var modifiedAfter: [Date]

    public init(
        contentKind: MacClippyContentKind? = nil,
        sourceAppContains: [String] = [],
        labelContains: [String] = [],
        requiresLabel: Bool = false,
        requiresOCR: Bool = false,
        modifiedBefore: [Date] = [],
        modifiedAfter: [Date] = []
    ) {
        self.contentKind = contentKind
        self.sourceAppContains = sourceAppContains
        self.labelContains = labelContains
        self.requiresLabel = requiresLabel
        self.requiresOCR = requiresOCR
        self.modifiedBefore = modifiedBefore
        self.modifiedAfter = modifiedAfter
    }
}

public struct MacClippyStoredPayloadFootprint: Sendable, Equatable {
    public let inlineBytes: Int
    public let blobIDs: Set<String>

    public init(inlineBytes: Int, blobIDs: Set<String>) {
        self.inlineBytes = max(0, inlineBytes)
        self.blobIDs = blobIDs
    }
}

/// A durable marker for a cross-database clipboard deletion. The clipboard
/// database is the source of truth for the operation; FTS, pinboards, and
/// external blobs can be replayed idempotently if the process exits midway.
public struct MacClippyDeletionJournalEntry: Sendable, Equatable {
    public let operationID: String
    public let recordIDs: [RecordID]
    public let blobIDs: Set<String>

    public init(operationID: String, recordIDs: [RecordID], blobIDs: Set<String>) {
        self.operationID = operationID
        self.recordIDs = recordIDs
        self.blobIDs = blobIDs
    }
}

public final class MacClippyClipboardStore {
    public static let migrations: [MacClippyDatabaseMigration] = [
        MacClippyDatabaseMigration(identifier: "001-clipboard-core") { database in
            try database.execute(sql: MacClippyClipboardStore.schemaSQL)
        },
        // P0 no-filter capture: a side table that retains every external
        // NSPasteboard representation (UTI + encrypted Data, or BlobStore id)
        // for a clipboard record. The legacy single-payload envelope column is
        // preserved so existing local records continue to decode and existing
        // call sites keep working.
        MacClippyDatabaseMigration(identifier: "002-clipboard-representations") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS clipboard_representations (
                    record_id TEXT NOT NULL,
                    sort_order INTEGER NOT NULL,
                    uti TEXT NOT NULL,
                    payload BLOB,
                    blob_id TEXT,
                    payload_state TEXT NOT NULL DEFAULT 'present',
                    PRIMARY KEY(record_id, uti),
                    FOREIGN KEY(record_id) REFERENCES clipboard_records(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_macclippy_repr_blob
                    ON clipboard_representations(blob_id);
            """)
        },
        // Structured `type:` queries and image-only maintenance passes use
        // the persisted discriminator instead of decrypting every envelope.
        MacClippyDatabaseMigration(identifier: "003-clipboard-query-indexes") { database in
            try database.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_macclippy_records_content_kind
                    ON clipboard_records(content_kind);
            """)
        },
        // Cross-database deletion is intentionally journaled in the clipboard
        // database, which is already protected by the runtime store lock.
        // FTS/pinboard cleanup and external blob deletion can then be retried
        // after a force quit without guessing whether the parent row existed.
        MacClippyDatabaseMigration(identifier: "004-deletion-journal") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS clipboard_deletion_operations (
                    operation_id TEXT PRIMARY KEY NOT NULL,
                    created INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS clipboard_deletion_journal (
                    operation_id TEXT NOT NULL,
                    record_id TEXT NOT NULL,
                    blob_id TEXT NOT NULL,
                    PRIMARY KEY(operation_id, record_id, blob_id),
                    FOREIGN KEY(operation_id)
                        REFERENCES clipboard_deletion_operations(operation_id)
                        ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_macclippy_deletion_record
                    ON clipboard_deletion_journal(record_id);
            """)
        },
        // Keep record IDs independently of Blob IDs. A text-only deletion has
        // no representation/blob row, but its cross-database cleanup still
        // needs to be replayable after a force quit.
        MacClippyDatabaseMigration(identifier: "005-deletion-records") { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS clipboard_deletion_records (
                    operation_id TEXT NOT NULL,
                    record_id TEXT NOT NULL,
                    PRIMARY KEY(operation_id, record_id),
                    FOREIGN KEY(operation_id)
                        REFERENCES clipboard_deletion_operations(operation_id)
                        ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_macclippy_deletion_records_record
                    ON clipboard_deletion_records(record_id);
                INSERT OR IGNORE INTO clipboard_deletion_records(operation_id, record_id)
                    SELECT DISTINCT operation_id, record_id
                    FROM clipboard_deletion_journal;
            """)
        }
    ]

    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS clipboard_records (
            id TEXT PRIMARY KEY NOT NULL,
            created INTEGER NOT NULL,
            modified INTEGER NOT NULL,
            device_id TEXT NOT NULL,
            lamport INTEGER NOT NULL,
            kind TEXT NOT NULL,
            content_kind TEXT NOT NULL,
            preview TEXT NOT NULL,
            source_app TEXT,
            frequency INTEGER NOT NULL DEFAULT 0,
            last_accessed INTEGER,
            custom_label TEXT,
            detected_type TEXT,
            ocr_text TEXT,
            envelope BLOB NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_macclippy_records_modified
            ON clipboard_records(modified DESC, lamport DESC, id DESC);
        CREATE INDEX IF NOT EXISTS idx_macclippy_records_frequency
            ON clipboard_records(frequency DESC, modified DESC);
        CREATE TABLE IF NOT EXISTS macclippy_lamport_clock (
            scope TEXT PRIMARY KEY NOT NULL,
            value INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO macclippy_lamport_clock(scope, value) VALUES ('clipboard', 0);
    """

    private let database: MacClippyDatabase
    private let key: SymmetricKey
    private let deviceID: DeviceID
    private let inputLimits: MacClippyPasteboardInputLimits

    public init(
        database: MacClippyDatabase,
        deviceKey: SymmetricKey,
        deviceID: DeviceID = .generate(),
        inputLimits: MacClippyPasteboardInputLimits = .default
    ) throws {
        self.database = database
        key = deviceKey
        self.deviceID = deviceID
        self.inputLimits = inputLimits
        try database.migrate(Self.migrations)
    }

    public func databaseHealth() -> MacClippyDatabaseHealthReport {
        database.healthCheck(requiredTables: [
            "clipboard_records",
            "clipboard_representations",
            "clipboard_deletion_operations",
            "clipboard_deletion_journal",
            "clipboard_deletion_records",
            "grdb_migrations"
        ])
    }

    public func databaseRowCount() -> Int64? {
        database.tableRowCount("clipboard_records")
    }

    @discardableResult
    public func append(
        _ record: ClipboardRecord,
        sourceAppBundleID: String? = nil,
        detectedTypeJSON: String? = nil,
        now: Date = Date()
    ) throws -> ClipboardItemMeta {
        let id = RecordID.generate()
        let envelope = try MacClippyCipher.seal(try encodedRecordData(record), with: key)
        let milliseconds = Self.milliseconds(now)
        let lamport = try database.queue.write { database -> UInt64 in
            let current = try Int64.fetchOne(database, sql: "SELECT value FROM macclippy_lamport_clock WHERE scope = 'clipboard'") ?? 0
            let next = current == Int64.max ? current : current + 1
            try database.execute(sql: "UPDATE macclippy_lamport_clock SET value = ? WHERE scope = 'clipboard'", arguments: [next])
            try database.execute(sql: """
                INSERT INTO clipboard_records
                    (id, created, modified, device_id, lamport, kind, content_kind, preview,
                     source_app, detected_type, envelope)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                id.rawValue, milliseconds, milliseconds, deviceID.rawValue, next,
                RecordKind.clipboardItem.rawValue, record.contentKind.rawValue,
                Self.preview(for: record), sourceAppBundleID, detectedTypeJSON, envelope.combined
            ])
            return UInt64(next)
        }
        return ClipboardItemMeta(
            id: id, created: now, modified: now, deviceID: deviceID, lamport: lamport,
            preview: Self.preview(for: record), sourceAppBundleID: sourceAppBundleID,
            detectedTypeJSON: detectedTypeJSON
        )
    }

    // P0 no-filter capture entry point. Persists the legacy single-payload
    // envelope (so existing cards/preview/paste keep working) AND every
    // external NSPasteboard representation alongside it. Representation
    // payloads are encrypted at rest inline; oversized payloads are spilled
    // to BlobStore via the spillPayload closure so the store stays unaware of
    // the blob root URL while still keeping encryption on the spilled bytes.
    //
    // The parent clipboard_records row and every clipboard_representations
    // row are written inside a single database transaction so a crash or
    // failure mid-capture can never leave a visible record without its
    // retained representation set. Spilled blobs are created before the
    // transaction commits (BlobStore writes are outside the DB transaction);
    // if the transaction fails, any blob spilled during this call is deleted
    // via deleteSpilledPayload as a compensating rollback before the error
    // propagates, so no orphan blob is left behind by a failed append. When
    // deleteSpilledPayload is nil, spilled-blob cleanup is deferred to
    // startup reconciliation (the orphan will be detected and trimmed later).
    // Empty advertised payloads are retained as empty inline rows; provider-
    // unavailable payloads are retained as type-only rows with payloadState
    // .unavailable.
    @discardableResult
    public func append(
        _ record: ClipboardRecord,
        representations: [MacClippyClipboardRepresentation],
        sourceAppBundleID: String? = nil,
        detectedTypeJSON: String? = nil,
        spillPayload: ((Data) throws -> String)? = nil,
        deleteSpilledPayload: ((String) -> Void)? = nil,
        now: Date = Date()
    ) throws -> ClipboardItemMeta {
        let id = RecordID.generate()
        let envelope = try MacClippyCipher.seal(try encodedRecordData(record), with: key)
        let milliseconds = Self.milliseconds(now)

        var totalRepresentationBytes = 0
        for representation in representations {
            guard let payloadBytes = representation.payloadBytes else { continue }
            guard payloadBytes.count <= inputLimits.maxRepresentationBytes else {
                throw MacClippyStoreError.inputTooLarge
            }
            totalRepresentationBytes += payloadBytes.count
            guard totalRepresentationBytes <= inputLimits.maxChangeBytes else {
                throw MacClippyStoreError.inputTooLarge
            }
        }

        // Spill oversized payloads up front, outside the DB transaction, so the
        // spilled blob IDs are known before we write any rows. Track every blob
        // created here so a later failure rolls them back via compensating
        // delete. A spill failure aborts before any row is written, so no
        // record and no representation can be left visible. If a later
        // representation's preparation (spill or inline encryption) throws
        // after an earlier representation already spilled, the already-spilled
        // blobs are cleaned up via deleteSpilledPayload before rethrowing.
        var spilledBlobIDs: [String] = []
        var preparedRows: [PreparedRepresentationRow] = []
        do {
            for (index, representation) in representations.enumerated() {
                let row = try prepareRepresentationRow(
                    representation,
                    atIndex: index,
                    recordID: id,
                    spillPayload: spillPayload,
                    spilledBlobIDs: &spilledBlobIDs
                )
                preparedRows.append(row)
            }
        } catch {
            if let deleteSpilledPayload {
                for blobID in spilledBlobIDs {
                    deleteSpilledPayload(blobID)
                }
            }
            throw error
        }

        let lamport: UInt64
        do {
            lamport = try database.queue.write { database -> UInt64 in
                let current = try Int64.fetchOne(database, sql: "SELECT value FROM macclippy_lamport_clock WHERE scope = 'clipboard'") ?? 0
                let next = current == Int64.max ? current : current + 1
                try database.execute(sql: "UPDATE macclippy_lamport_clock SET value = ? WHERE scope = 'clipboard'", arguments: [next])
                try database.execute(sql: """
                    INSERT INTO clipboard_records
                        (id, created, modified, device_id, lamport, kind, content_kind, preview,
                         source_app, detected_type, envelope)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    id.rawValue, milliseconds, milliseconds, deviceID.rawValue, next,
                    RecordKind.clipboardItem.rawValue, record.contentKind.rawValue,
                    Self.preview(for: record), sourceAppBundleID, detectedTypeJSON, envelope.combined
                ])

                for row in preparedRows {
                    try database.execute(
                        sql: """
                            INSERT OR REPLACE INTO clipboard_representations
                                (record_id, sort_order, uti, payload, blob_id, payload_state)
                            VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [id.rawValue, row.sortOrder, row.uti, row.storedPayload, row.storedBlobID, row.payloadState.rawValue]
                    )
                }
                return UInt64(next)
            }
        } catch {
            // Compensating rollback: delete any blob spilled during this call
            // so a failed append never leaves an orphan blob on disk. The
            // database transaction rolled back on its own; BlobStore writes
            // are outside that transaction and must be cleaned manually. When
            // no delete closure is provided, the orphan is left for startup
            // reconciliation to reclaim.
            if let deleteSpilledPayload {
                for blobID in spilledBlobIDs {
                    deleteSpilledPayload(blobID)
                }
            }
            throw error
        }

        return ClipboardItemMeta(
            id: id, created: now, modified: now, deviceID: deviceID, lamport: lamport,
            preview: Self.preview(for: record), sourceAppBundleID: sourceAppBundleID,
            detectedTypeJSON: detectedTypeJSON
        )
    }

    private struct PreparedRepresentationRow {
        let sortOrder: Int
        let uti: String
        let storedPayload: Data?
        let storedBlobID: String?
        let payloadState: MacClippyClipboardRepresentationPayloadState
    }

    private func prepareRepresentationRow(
        _ representation: MacClippyClipboardRepresentation,
        atIndex index: Int,
        recordID: RecordID,
        spillPayload: ((Data) throws -> String)?,
        spilledBlobIDs: inout [String]
    ) throws -> PreparedRepresentationRow {
        // Provider-unavailable payload: retain the UTI as a type-only row.
        // payloadBytes and blobID are both nil; payloadState is .unavailable.
        if representation.isUnavailable {
            return PreparedRepresentationRow(
                sortOrder: index,
                uti: representation.uti,
                storedPayload: nil,
                storedBlobID: nil,
                payloadState: .unavailable
            )
        }

        if representation.isOversized {
            return PreparedRepresentationRow(
                sortOrder: index,
                uti: representation.uti,
                storedPayload: nil,
                storedBlobID: nil,
                payloadState: .oversized
            )
        }

        // Blob-backed representation carried through from mapping (already
        // spilled upstream). Keep the existing blobID and no inline payload.
        if let blobID = representation.blobID {
            return PreparedRepresentationRow(
                sortOrder: index,
                uti: representation.uti,
                storedPayload: nil,
                storedBlobID: blobID,
                payloadState: .spilled
            )
        }

        if let payloadBytes = representation.payloadBytes {
            guard payloadBytes.count <= inputLimits.maxRepresentationBytes else {
                throw MacClippyStoreError.inputTooLarge
            }
            if payloadBytes.count > MacClippyClipboardRepresentationLimits.inlineByteCeiling,
               let spillPayload {
                // Spill oversized payloads to BlobStore; the bytes are
                // encrypted by the spill closure before they hit disk.
                let blobID = try spillPayload(payloadBytes)
                spilledBlobIDs.append(blobID)
                return PreparedRepresentationRow(
                    sortOrder: index,
                    uti: representation.uti,
                    storedPayload: nil,
                    storedBlobID: blobID,
                    payloadState: .spilled
                )
            } else {
                // Inline encrypted payload: seal the plaintext bytes (which
                // may be empty — an advertised empty payload is retained as
                // an empty inline row) with the device key so the at-rest
                // format is always our AES-GCM envelope.
                let sealed = try MacClippyCipher.seal(payloadBytes, with: key)
                return PreparedRepresentationRow(
                    sortOrder: index,
                    uti: representation.uti,
                    storedPayload: sealed.combined,
                    storedBlobID: nil,
                    payloadState: .present
                )
            }
        }

        // A representation with no bytes and no blobID that was not marked
        // unavailable is treated as provider-unavailable so the UTI is still
        // retained rather than dropped.
        return PreparedRepresentationRow(
            sortOrder: index,
            uti: representation.uti,
            storedPayload: nil,
            storedBlobID: nil,
            payloadState: .unavailable
        )
    }

    private func encodedRecordData(_ record: ClipboardRecord) throws -> Data {
        let data = try JSONEncoder().encode(record)
        guard data.count <= inputLimits.maxRecordBytes else { throw MacClippyStoreError.inputTooLarge }
        return data
    }

    public func list(
        limit: Int,
        offset: Int = 0,
        contentKind: MacClippyContentKind? = nil,
        filter: MacClippyClipboardMetadataFilter? = nil
    ) throws -> [ClipboardItemMeta] {
        guard limit > 0 else { return [] }
        return try database.queue.read { connection in
            var predicates: [String] = []
            var rawArguments: [Any] = []
            let activeFilter = filter ?? MacClippyClipboardMetadataFilter(contentKind: contentKind)

            if let contentKind = activeFilter.contentKind {
                predicates.append("content_kind = ?")
                rawArguments.append(contentKind.rawValue)
            }
            for value in activeFilter.sourceAppContains {
                predicates.append("LOWER(source_app) LIKE LOWER(?) ESCAPE '\\'")
                rawArguments.append(Self.likePattern(for: value))
            }
            for value in activeFilter.labelContains {
                predicates.append("LOWER(custom_label) LIKE LOWER(?) ESCAPE '\\'")
                rawArguments.append(Self.likePattern(for: value))
            }
            if activeFilter.requiresLabel {
                predicates.append("custom_label IS NOT NULL AND trim(custom_label) != ''")
            }
            if activeFilter.requiresOCR {
                predicates.append("ocr_text IS NOT NULL AND trim(ocr_text) != ''")
            }
            for date in activeFilter.modifiedBefore {
                predicates.append("modified < ?")
                rawArguments.append(Self.milliseconds(date))
            }
            for date in activeFilter.modifiedAfter {
                predicates.append("modified >= ?")
                rawArguments.append(Self.milliseconds(date))
            }

            var sql = """
                SELECT id, created, modified, device_id, lamport, kind, preview, source_app,
                       frequency, last_accessed, custom_label, detected_type, ocr_text
                FROM clipboard_records
            """
            if !predicates.isEmpty {
                sql += " WHERE " + predicates.joined(separator: " AND ")
            }
            sql += " ORDER BY modified DESC, lamport DESC, id DESC LIMIT ? OFFSET ?"
            rawArguments.append(limit)
            rawArguments.append(max(0, offset))
            return try Row.fetchAll(connection, sql: sql, arguments: StatementArguments(rawArguments)!).map(Self.meta)
        }
    }

    public func contentKinds(for ids: [RecordID]) throws -> [RecordID: MacClippyContentKind] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try database.queue.read { connection in
            try Row.fetchAll(
                connection,
                sql: "SELECT id, content_kind FROM clipboard_records WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids.map(\.rawValue))
            ).reduce(into: [RecordID: MacClippyContentKind]()) { result, row in
                guard let id = RecordID(rawValue: row["id"] as String),
                      let contentKind = MacClippyContentKind(rawValue: row["content_kind"] as String) else { return }
                result[id] = contentKind
            }
        }
    }

    public func metas(for ids: [RecordID]) throws -> [ClipboardItemMeta] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let rows = try database.queue.read { connection in
            try Row.fetchAll(connection, sql: """
                SELECT id, created, modified, device_id, lamport, kind, preview, source_app,
                       frequency, last_accessed, custom_label, detected_type, ocr_text
                FROM clipboard_records WHERE id IN (\(placeholders))
            """, arguments: StatementArguments(ids.map(\.rawValue)))
        }
        let values = try rows.map(Self.meta)
        let byID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    public func body(for id: RecordID) throws -> ClipboardRecord {
        let data: Data = try database.queue.read { connection in
            guard let row = try Row.fetchOne(connection, sql: "SELECT envelope FROM clipboard_records WHERE id = ?", arguments: [id.rawValue]) else {
                throw MacClippyStoreError.recordNotFound
            }
            guard let value = row["envelope"] as Data? else { throw MacClippyStoreError.invalidStoredRecord }
            return value
        }
        return try JSONDecoder().decode(ClipboardRecord.self, from: MacClippyCipher.open(MacClippyEnvelope(combined: data), with: key))
    }

    // Atomically replaces the editable primary payload and its card metadata.
    // Retained representation rows are deliberately updated in place: only
    // the canonical representation for the edited content kind is changed;
    // every other advertised UTI remains untouched.
    @discardableResult
    public func update(id: RecordID, with record: ClipboardRecord, now: Date = Date()) throws -> ClipboardItemMeta {
        let envelope = try MacClippyCipher.seal(try JSONEncoder().encode(record), with: key)
        let milliseconds = Self.milliseconds(now)
        let primaryBytes = Self.primaryRepresentationBytes(for: record)
        let primaryUTIs = Self.primaryRepresentationUTIs(for: record)

        try database.queue.write { connection in
            guard try Row.fetchOne(connection, sql: "SELECT id FROM clipboard_records WHERE id = ?", arguments: [id.rawValue]) != nil else {
                throw MacClippyStoreError.recordNotFound
            }
            try connection.execute(sql: """
                UPDATE clipboard_records
                SET modified = ?, content_kind = ?, preview = ?, envelope = ?
                WHERE id = ?
            """, arguments: [
                milliseconds, record.contentKind.rawValue, Self.preview(for: record), envelope.combined, id.rawValue
            ])

            if let primaryBytes,
               let row = try Row.fetchOne(
                   connection,
                   sql: "SELECT uti FROM clipboard_representations WHERE record_id = ? AND uti IN (\(Array(repeating: "?", count: primaryUTIs.count).joined(separator: ","))) ORDER BY sort_order LIMIT 1",
                   arguments: StatementArguments([id.rawValue] + primaryUTIs)
               ) {
                let uti: String = row["uti"]
                let sealed = try MacClippyCipher.seal(primaryBytes, with: key)
                try connection.execute(sql: """
                    UPDATE clipboard_representations
                    SET payload = ?, blob_id = NULL, payload_state = 'present'
                    WHERE record_id = ? AND uti = ?
                """, arguments: [sealed.combined, id.rawValue, uti])
            }
        }

        guard let meta = try metas(for: [id]).first else { throw MacClippyStoreError.recordNotFound }
        return meta
    }

    // Batch body reads for pinboard/history projections. This keeps the SQL
    // work and database queue hop at one operation instead of one SELECT per
    // record; decryption still happens once per envelope outside the read
    // transaction.
    public func bodies(for ids: [RecordID]) throws -> [RecordID: ClipboardRecord] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let envelopes: [(String, Data)] = try database.queue.read { connection in
            try Row.fetchAll(
                connection,
                sql: "SELECT id, envelope FROM clipboard_records WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids.map(\.rawValue))
            ).compactMap { row in
                guard let rawID: String = row["id"], let envelope: Data = row["envelope"] else { return nil }
                return (rawID, envelope)
            }
        }

        var values: [RecordID: ClipboardRecord] = [:]
        values.reserveCapacity(envelopes.count)
        for (rawID, envelope) in envelopes {
            guard let id = RecordID(rawValue: rawID) else { continue }
            values[id] = try JSONDecoder().decode(
                ClipboardRecord.self,
                from: MacClippyCipher.open(MacClippyEnvelope(combined: envelope), with: key)
            )
        }
        return values
    }

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
    public func referencedBlobIDs(excluding recordIDs: Set<RecordID> = []) throws -> Set<String> {
        let representationIDs = try database.queue.read { connection in
            try Row.fetchAll(
                connection,
                sql: "SELECT DISTINCT blob_id FROM clipboard_representations WHERE blob_id IS NOT NULL"
            ).compactMap { $0["blob_id"] as String? }
        }

        var ids = Set(representationIDs)
        // The legacy blob reference can only be present in image records.
        // Use the persisted content_kind discriminator before decrypting so
        // retention and delete cleanup do not walk every historical envelope.
        for meta in try list(limit: Int.max, contentKind: .image) where !recordIDs.contains(meta.id) {
            // A failed decrypt/decode is not evidence that the record has no
            // Blob reference. Propagate the error so deletion/retention aborts
            // before it can delete a Blob belonging to a corrupt record.
            if let blobID = try body(for: meta.id).imageBlobID {
                ids.insert(blobID)
            }
        }
        return ids
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
        if try contentKinds(for: [id])[id] == .image,
           let primary = try body(for: id).imageBlobID {
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
        try database.queue.read { connection in
            let operations = try Row.fetchAll(
                connection,
                sql: "SELECT operation_id FROM clipboard_deletion_operations ORDER BY created ASC"
            )
            return try operations.map { operation in
                let operationID: String = operation["operation_id"]
                let recordIDs = try Row.fetchAll(
                    connection,
                    sql: """
                        SELECT record_id
                        FROM clipboard_deletion_records
                        WHERE operation_id = ?
                        ORDER BY record_id ASC
                    """,
                    arguments: [operationID]
                ).compactMap { row -> RecordID? in
                    guard let rawID: String = row["record_id"] else { return nil }
                    return RecordID(rawValue: rawID)
                }
                let rows = try Row.fetchAll(
                    connection,
                    sql: """
                        SELECT record_id, blob_id
                        FROM clipboard_deletion_journal
                        WHERE operation_id = ?
                        ORDER BY record_id ASC, blob_id ASC
                    """,
                    arguments: [operationID]
                )
                var blobIDs = Set<String>()
                for row in rows {
                    if let blobID: String = row["blob_id"] {
                        blobIDs.insert(blobID)
                    }
                }
                return MacClippyDeletionJournalEntry(
                    operationID: operationID,
                    recordIDs: recordIDs,
                    blobIDs: blobIDs
                )
            }
        }
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
    public func storageFootprint(for id: RecordID) throws -> MacClippyStoredPayloadFootprint {
        let body = try body(for: id)
        let encodedBodyBytes = try JSONEncoder().encode(body).count
        let representationBytes = try database.queue.read { connection in
            try Int.fetchOne(
                connection,
                sql: "SELECT COALESCE(SUM(length(payload)), 0) FROM clipboard_representations WHERE record_id = ?",
                arguments: [id.rawValue]
            ) ?? 0
        }
        return MacClippyStoredPayloadFootprint(
            inlineBytes: encodedBodyBytes + representationBytes,
            blobIDs: try blobIDs(for: id)
        )
    }

    public func delete(id: RecordID) throws {
        try database.queue.write { connection in
            try connection.execute(sql: "DELETE FROM clipboard_records WHERE id = ?", arguments: [id.rawValue])
        }
    }

    public func bumpFrequency(id: RecordID, now: Date = Date()) throws {
        try database.queue.write { connection in
            try connection.execute(sql: """
                UPDATE clipboard_records SET frequency = frequency + 1, last_accessed = ? WHERE id = ?
            """, arguments: [Self.milliseconds(now), id.rawValue])
        }
    }

    // P2a: set or clear a trimmed custom label for a clipboard record. A
    // blank/whitespace-only label is normalized to nil so blank input clears
    // the label rather than persisting an empty string. The record's modified
    // timestamp is bumped so the card reflects the edit and ordering by
    // `modified DESC` stays meaningful after a label edit. Returns the updated
    // meta so the runtime can reindex the search store and the dock can
    // refresh the card without an extra read. Throws recordNotFound when the
    // id is not present so the runtime never reindexes a row that was deleted
    // concurrently.
    @discardableResult
    public func setCustomLabel(id: RecordID, label: String?, now: Date = Date()) throws -> ClipboardItemMeta {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        let milliseconds = Self.milliseconds(now)
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET custom_label = ?, modified = ? WHERE id = ?",
                arguments: [normalized, milliseconds, id.rawValue]
            )
            // changesCount is the row count touched by the UPDATE that just
            // ran. A zero count means the id was not present; surface
            // recordNotFound so the runtime never reindexes a row that was
            // deleted concurrently.
            guard connection.changesCount > 0 else { throw MacClippyStoreError.recordNotFound }
        }
        guard let meta = (try metas(for: [id])).first else { throw MacClippyStoreError.recordNotFound }
        return meta
    }

    public func setOCRText(id: RecordID, text: String?) throws {
        try database.queue.write { connection in
            try connection.execute(sql: "UPDATE clipboard_records SET ocr_text = ? WHERE id = ?", arguments: [text, id.rawValue])
        }
    }

    public func recentByFrequency(limit: Int, offset: Int = 0) throws -> [ClipboardItemMeta] {
        guard limit > 0 else { return [] }
        return try database.queue.read { connection in
            try Row.fetchAll(connection, sql: """
                SELECT id, created, modified, device_id, lamport, kind, preview, source_app,
                       frequency, last_accessed, custom_label, detected_type, ocr_text
                FROM clipboard_records ORDER BY frequency DESC, modified DESC, id DESC LIMIT ? OFFSET ?
            """, arguments: [limit, max(0, offset)]).map(Self.meta)
        }
    }

    public func allMetas() throws -> [ClipboardItemMeta] {
        try list(limit: Int.max)
    }

    // Returns every retained representation for a record, decrypting inline
    // payloads and leaving blob-backed payloads for the caller to read via
    // BlobStore. Returns an empty set for legacy records that predate the 002
    // migration, so callers can always treat missing representations as
    // "no extra slots captured" rather than a missing-table error. Rows with
    // payload_state 'unavailable' are returned as type-only markers (nil
    // payloadBytes, nil blobID) so the advertised type set is complete even
    // when the provider never materialized the bytes.
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
                let stateString: String = (row["payload_state"] as String?) ?? MacClippyClipboardRepresentationPayloadState.present.rawValue
                let payloadState = MacClippyClipboardRepresentationPayloadState(rawValue: stateString) ?? .present

                switch payloadState {
                case .unavailable:
                    return MacClippyClipboardRepresentation(uti: uti, payloadBytes: nil, blobID: nil, payloadState: .unavailable)
                case .oversized:
                    return MacClippyClipboardRepresentation(uti: uti, payloadBytes: nil, blobID: nil, payloadState: .oversized)
                case .spilled:
                    return MacClippyClipboardRepresentation(uti: uti, payloadBytes: nil, blobID: blobID, payloadState: .spilled)
                case .present:
                    guard let payload else {
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

    // All BlobStore identifiers referenced by the representation side table.
    // Used by startup reconciliation to detect orphan blobs that are no longer
    // referenced by any record (e.g. after a crash mid-capture).
    public func allRepresentationBlobIDs() throws -> Set<String> {
        try database.queue.read { connection in
            let rows = try Row.fetchAll(
                connection,
                sql: "SELECT DISTINCT blob_id FROM clipboard_representations WHERE blob_id IS NOT NULL"
            )
            return Set(rows.compactMap { $0["blob_id"] as String? })
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

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    private static func likePattern(for value: String) -> String {
        "%" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    private static func preview(for record: ClipboardRecord) -> String {
        switch record {
        case let .text(value): String(value.prefix(120))
        case .rtf: "(rich text)"
        case let .html(value): String(stripHTML(value).prefix(120))
        case let .image(_, width, height), let .encryptedImage(_, width, height): "(image \(width)x\(height))"
        case let .files(urls): "(\(urls.count) file\(urls.count == 1 ? "" : "s"))"
        }
    }

    private static func primaryRepresentationUTIs(for record: ClipboardRecord) -> [String] {
        switch record {
        case .text: ["public.utf8-plain-text", "public.text", "NSStringPboardType"]
        case .html: ["public.html"]
        case .rtf: ["public.rtf"]
        case .image, .encryptedImage: ["public.png", "public.tiff", "public.jpeg", "public.image"]
        case .files: ["public.file-url", "public.url"]
        }
    }

    private static func primaryRepresentationBytes(for record: ClipboardRecord) -> Data? {
        switch record {
        case let .text(value), let .html(value): value.data(using: .utf8)
        case let .rtf(data): data
        default: nil
        }
    }

    private static func stripHTML(_ html: String) -> String {
        var result = html.replacingOccurrences(of: "<script\\b[^>]*>[\\s\\S]*?</script>", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "<style\\b[^>]*>[\\s\\S]*?</style>", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, replacement) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func meta(_ row: Row) throws -> ClipboardItemMeta {
        guard let id = RecordID(rawValue: row["id"]),
              let deviceID = DeviceID(rawValue: row["device_id"]),
              let kind = RecordKind(rawValue: row["kind"] as String) else { throw MacClippyStoreError.invalidStoredRecord }
        let lastAccessed: Int64? = row["last_accessed"]
        return ClipboardItemMeta(
            id: id,
            created: Date(timeIntervalSince1970: Double(row["created"] as Int64) / 1_000),
            modified: Date(timeIntervalSince1970: Double(row["modified"] as Int64) / 1_000),
            deviceID: deviceID,
            lamport: UInt64(row["lamport"] as Int64),
            kind: kind,
            preview: row["preview"],
            sourceAppBundleID: row["source_app"],
            frequency: Int(row["frequency"] as Int64? ?? 0),
            lastAccessed: lastAccessed.map { Date(timeIntervalSince1970: Double($0) / 1_000) },
            customLabel: row["custom_label"],
            detectedTypeJSON: row["detected_type"],
            ocrText: row["ocr_text"]
        )
    }
}

public typealias ClipboardStore = MacClippyClipboardStore
