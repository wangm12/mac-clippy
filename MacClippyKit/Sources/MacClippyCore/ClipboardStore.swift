import CryptoKit
import Foundation
import GRDB

public enum MacClippyStoreError: Error, Sendable {
    case recordNotFound
    case invalidStoredRecord
    case inputTooLarge
    case unprovenLegacyAttachmentReferences
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

    public static func fromStructuredQuery(
        _ query: MacClippySearchGrammar.Query,
        contentKind: MacClippyContentKind? = nil
    ) -> MacClippyClipboardMetadataFilter {
        var filter = MacClippyClipboardMetadataFilter(contentKind: contentKind)
        for clause in query.clauses {
            switch clause {
            case let .app(value):
                filter.sourceAppContains.append(value)
            case let .label(value):
                filter.labelContains.append(value)
            case .hasLabel:
                filter.requiresLabel = true
            case .hasOCR:
                filter.requiresOCR = true
            case let .before(date):
                filter.modifiedBefore.append(date)
            case let .after(date):
                filter.modifiedAfter.append(date)
            case .bare, .type, .url:
                break
            }
        }
        return filter
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

    let database: MacClippyDatabase
    let key: SymmetricKey
    let deviceID: DeviceID
    let inputLimits: MacClippyPasteboardInputLimits
    private let decryptAccountingLock = NSLock()
    private var representationPayloadDecrypts = 0
    private var recordEnvelopeDecrypts = 0

    public var representationPayloadDecryptCount: Int {
        decryptAccountingLock.lock()
        defer { decryptAccountingLock.unlock() }
        return representationPayloadDecrypts
    }

    public var recordEnvelopeDecryptCount: Int {
        decryptAccountingLock.lock()
        defer { decryptAccountingLock.unlock() }
        return recordEnvelopeDecrypts
    }

    func noteRepresentationPayloadDecrypt() {
        decryptAccountingLock.lock()
        representationPayloadDecrypts += 1
        decryptAccountingLock.unlock()
    }

    func noteRecordEnvelopeDecrypt() {
        decryptAccountingLock.lock()
        recordEnvelopeDecrypts += 1
        decryptAccountingLock.unlock()
    }

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

    public func databaseHealth(
        mode: MacClippyDatabaseHealthCheckMode = .bounded
    ) -> MacClippyDatabaseHealthReport {
        database.healthCheck(requiredTables: [
            "clipboard_records",
            "clipboard_representations",
            "clipboard_deletion_operations",
            "clipboard_deletion_journal",
            "clipboard_deletion_records",
            "macclippy_clipboard_state",
            "grdb_migrations"
        ], mode: mode)
    }

    public func databaseRowCount() throws -> Int64? {
        try database.tableRowCount("clipboard_records")
    }

    func encodedRecordData(
        _ record: ClipboardRecord,
        requiresRepresentationRoster: Bool = true
    ) throws -> Data {
        guard record.imageBlobID.map(MacClippyBlobStore.isSafeIdentifier) ?? true else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        let data = try MacClippyClipboardRecordEnvelopeCodec.encode(
            record,
            requiresRepresentationRoster: requiresRepresentationRoster
        )
        guard data.count <= inputLimits.maxRecordBytes else { throw MacClippyStoreError.inputTooLarge }
        return data
    }

    func validateRepresentationLimits(
        _ representations: [MacClippyClipboardRepresentation]
    ) throws {
        guard representations.count <= inputLimits.maxRepresentationsPerRecord else {
            throw MacClippyStoreError.inputTooLarge
        }
        var totalRepresentationBytes = 0
        var representationCountsByItem: [Int: Int] = [:]
        var seenItemTypes = Set<String>()
        for representation in representations {
            guard representation.itemIndex >= 0,
                  representation.itemIndex < inputLimits.maxItemsPerChange,
                  seenItemTypes.insert("\(representation.itemIndex)\u{0}\(representation.uti)").inserted else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            let itemCount = representationCountsByItem[representation.itemIndex, default: 0] + 1
            guard itemCount <= inputLimits.maxRepresentationsPerItem else {
                throw MacClippyStoreError.inputTooLarge
            }
            representationCountsByItem[representation.itemIndex] = itemCount
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
        case let .files(urls): MacClippyFilePresentation.persistPreview(for: urls)
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
            sourceAppDisplayName: row["source_app_name"],
            frequency: Int(row["frequency"] as Int64? ?? 0),
            lastAccessed: lastAccessed.map { Date(timeIntervalSince1970: Double($0) / 1_000) },
            customLabel: row["custom_label"],
            detectedTypeJSON: row["detected_type"],
            ocrText: row["ocr_text"]
        )
    }
}

public typealias ClipboardStore = MacClippyClipboardStore
