import CryptoKit
import Foundation
import GRDB

public struct MacClippyClipboardHistoryCursor: Sendable, Equatable {
    public let modified: Date
    public let lamport: UInt64
    public let id: RecordID

    public init(modified: Date, lamport: UInt64, id: RecordID) {
        self.modified = modified
        self.lamport = lamport
        self.id = id
    }
}

extension MacClippyClipboardStore {
    public func list(
        limit: Int,
        offset: Int = 0,
        contentKind: MacClippyContentKind? = nil,
        filter: MacClippyClipboardMetadataFilter? = nil,
        before cursor: MacClippyClipboardHistoryCursor? = nil
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
            if let cursor {
                predicates.append("(modified < ? OR (modified = ? AND lamport < ?) OR (modified = ? AND lamport = ? AND id < ?))")
                let milliseconds = Self.milliseconds(cursor.modified)
                rawArguments += [milliseconds, milliseconds, Int64(cursor.lamport), milliseconds, Int64(cursor.lamport), cursor.id.rawValue]
            }

            var sql = """
                SELECT id, created, modified, device_id, lamport, kind, content_kind, preview, source_app,
                       frequency, last_accessed, custom_label, detected_type, ocr_text
                FROM clipboard_records
            """
            if !predicates.isEmpty {
                sql += " WHERE " + predicates.joined(separator: " AND ")
            }
            sql += " ORDER BY modified DESC, lamport DESC, id DESC LIMIT ? OFFSET ?"
            rawArguments.append(limit)
            rawArguments.append(cursor == nil ? max(0, offset) : 0)
            guard let arguments = StatementArguments(rawArguments) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return try Row.fetchAll(connection, sql: sql, arguments: arguments).map(Self.meta)
        }
    }

    public func recentByFrequency(limit: Int, offset: Int = 0) throws -> [ClipboardItemMeta] {
        guard limit > 0 else { return [] }
        return try database.queue.read { connection in
            try Row.fetchAll(connection, sql: """
                SELECT id, created, modified, device_id, lamport, kind, content_kind, preview, source_app,
                       frequency, last_accessed, custom_label, detected_type, ocr_text
                FROM clipboard_records ORDER BY frequency DESC, modified DESC, id DESC LIMIT ? OFFSET ?
            """, arguments: [limit, max(0, offset)]).map(Self.meta)
        }
    }

    /// Reads history from oldest to newest using a stable keyset cursor. The
    /// lifecycle-bound delete-all path uses this instead of OFFSET so inserts
    /// or deletes between bounded pages cannot shift an unvisited record past
    /// the next page boundary.
    public func listOldest(
        limit: Int,
        after cursor: MacClippyClipboardHistoryCursor? = nil,
        contentKind: MacClippyContentKind? = nil
    ) throws -> [ClipboardItemMeta] {
        guard limit > 0 else { return [] }
        return try database.queue.read { connection in
            var sql = """
                SELECT id, created, modified, device_id, lamport, kind, content_kind, preview, source_app,
                       frequency, last_accessed, custom_label, detected_type, ocr_text
                FROM clipboard_records
            """
            var predicates: [String] = []
            var arguments: [Any] = []
            if let contentKind {
                predicates.append("content_kind = ?")
                arguments.append(contentKind.rawValue)
            }
            if let cursor {
                predicates.append("(modified > ? OR (modified = ? AND lamport > ?) OR (modified = ? AND lamport = ? AND id > ?))")
                let milliseconds = Self.milliseconds(cursor.modified)
                arguments += [milliseconds, milliseconds, Int64(cursor.lamport), milliseconds, Int64(cursor.lamport), cursor.id.rawValue]
            }
            if !predicates.isEmpty {
                sql += " WHERE " + predicates.joined(separator: " AND ")
            }
            sql += " ORDER BY modified ASC, lamport ASC, id ASC LIMIT ?"
            arguments.append(limit)
            guard let statementArguments = StatementArguments(arguments) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return try Row.fetchAll(connection, sql: sql, arguments: statementArguments).map(Self.meta)
        }
    }

    // Returns every retained representation for a record, decrypting inline
    // payloads and leaving blob-backed payloads for the caller to read via
    // BlobStore. Returns an empty set for legacy records that predate the 002
    // migration, so callers can always treat missing representations as
    // "no extra slots captured" rather than a missing-table error. Rows with
    // payload_state 'unavailable' are returned as type-only markers (nil
    // payloadBytes, nil blobID) so the advertised type set is complete even
    // when the provider never materialized the bytes.
}
