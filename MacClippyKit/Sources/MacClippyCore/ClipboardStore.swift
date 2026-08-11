import CryptoKit
import Foundation
import GRDB

public enum MacClippyStoreError: Error, Sendable {
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

    // SQLite's default variable limit is commonly 999. Keep ID batches below
    // that ceiling with room for future query arguments, and de-duplicate
    // before querying so a repeated ID cannot cause duplicate work across
    // batches.
    static let sqliteIDBatchSize = 500

    static func uniqueIDs(_ ids: [RecordID]) -> [RecordID] {
        var seen = Set<RecordID>()
        var unique: [RecordID] = []
        unique.reserveCapacity(ids.count)
        for id in ids where seen.insert(id).inserted {
            unique.append(id)
        }
        return unique
    }

    static func idBatches(_ ids: [RecordID]) -> [[RecordID]] {
        let unique = uniqueIDs(ids)
        guard !unique.isEmpty else { return [] }
        return stride(from: 0, to: unique.count, by: sqliteIDBatchSize).map { start in
            Array(unique[start ..< min(start + sqliteIDBatchSize, unique.count)])
        }
    }

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

    let database: MacClippyDatabase
    let key: SymmetricKey
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

    public func databaseRowCount() throws -> Int64? {
        try database.tableRowCount("clipboard_records")
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
            contentKind: record.contentKind,
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

        guard representations.count <= inputLimits.maxRepresentationsPerRecord else {
            throw MacClippyStoreError.inputTooLarge
        }
        var totalRepresentationBytes = 0
        for representation in representations {
            guard representation.uti.utf8.count <= inputLimits.maxUTIBytes else {
                throw MacClippyStoreError.inputTooLarge
            }
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
            contentKind: record.contentKind,
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
        switch representation.payloadState {
        case .present:
            guard representation.payloadBytes != nil, representation.blobID == nil else {
                throw MacClippyStoreError.invalidStoredRecord
            }
        case .spilled:
            guard representation.payloadBytes == nil, representation.blobID != nil else {
                throw MacClippyStoreError.invalidStoredRecord
            }
        case .unavailable, .oversized:
            guard representation.payloadBytes == nil, representation.blobID == nil else {
                throw MacClippyStoreError.invalidStoredRecord
            }
        }

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













    static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    static func likePattern(for value: String) -> String {
        "%" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    static func preview(for record: ClipboardRecord) -> String {
        switch record {
        case let .text(value): String(value.prefix(120))
        case .rtf: "(rich text)"
        case let .html(value): String(stripHTML(value).prefix(120))
        case let .image(_, width, height), let .encryptedImage(_, width, height): "(image \(width)x\(height))"
        case let .files(urls): "(\(urls.count) file\(urls.count == 1 ? "" : "s"))"
        }
    }

    static func primaryRepresentationUTIs(for record: ClipboardRecord) -> [String] {
        switch record {
        case .text: ["public.utf8-plain-text", "public.text", "NSStringPboardType"]
        case .html: ["public.html"]
        case .rtf: ["public.rtf"]
        case .image, .encryptedImage: ["public.png", "public.tiff", "public.jpeg", "public.image"]
        case .files: ["public.file-url", "public.url"]
        }
    }

    static func primaryRepresentationBytes(for record: ClipboardRecord) -> Data? {
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

    static func meta(_ row: Row) throws -> ClipboardItemMeta {
        guard let rawLamport: Int64 = row["lamport"], rawLamport >= 0 else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        guard let id = RecordID(rawValue: row["id"]),
              let deviceID = DeviceID(rawValue: row["device_id"]),
              let kind = RecordKind(rawValue: row["kind"] as String),
              let contentKind = MacClippyContentKind(rawValue: row["content_kind"] as String) else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        let lastAccessed: Int64? = row["last_accessed"]
        return ClipboardItemMeta(
            id: id,
            created: Date(timeIntervalSince1970: Double(row["created"] as Int64) / 1_000),
            modified: Date(timeIntervalSince1970: Double(row["modified"] as Int64) / 1_000),
            deviceID: deviceID,
            lamport: UInt64(rawLamport),
            kind: kind,
            contentKind: contentKind,
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
