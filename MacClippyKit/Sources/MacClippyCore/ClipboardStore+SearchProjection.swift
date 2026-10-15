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
    /// Enumerates only the IDs eligible for structured search, without loading
    /// preview/OCR fields or decrypting record envelopes.
    public func matchingRecordIDs(
        filter: MacClippyClipboardMetadataFilter,
        requiresURL: Bool = false,
        afterID: RecordID? = nil,
        limit: Int = 512,
        sourceAppDisplayNameResolver: (@Sendable (String?) -> String?)? = nil
    ) throws -> [RecordID] {
        guard limit > 0 else { return [] }
        return try database.queue.read { connection in
            let scope = Self.searchScopePredicates(
                filter, requiresURL: requiresURL, on: connection,
                resolver: sourceAppDisplayNameResolver
            )
            var predicates = scope.predicates
            var rawArguments = scope.rawArguments
            if let afterID {
                predicates.append("id > ?")
                rawArguments.append(afterID.rawValue)
            }
            var sql = "SELECT id FROM clipboard_records"
            if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
            sql += " ORDER BY id ASC LIMIT ?"
            rawArguments.append(limit)
            guard let arguments = StatementArguments(rawArguments) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return try String.fetchAll(connection, sql: sql, arguments: arguments).map { rawID in
                guard let id = RecordID(rawValue: rawID) else { throw MacClippyStoreError.invalidStoredRecord }
                return id
            }
        }
    }

    // SQL LOWER/LIKE only folds ASCII. Scope predicates must retain the Swift
    // grammar's Unicode matching and its fallback for legacy source app names.
    private static func searchScopePredicates(
        _ filter: MacClippyClipboardMetadataFilter,
        requiresURL: Bool,
        on connection: Database,
        resolver: (@Sendable (String?) -> String?)?
    ) -> (predicates: [String], rawArguments: [Any]) {
        var predicates: [String] = []
        var rawArguments: [Any] = []
        var basicFilter = filter
        basicFilter.sourceAppContains = []
        basicFilter.labelContains = []
        appendFilterPredicates(
            basicFilter, requiresURL: requiresURL, predicates: &predicates,
            rawArguments: &rawArguments, on: connection
        )
        if !filter.sourceAppContains.isEmpty {
            connection.add(function: DatabaseFunction("macclippy_source_app_contains", argumentCount: 3) { values in
                let bundleID = String.fromDatabaseValue(values[0])
                let storedName = String.fromDatabaseValue(values[1])
                let preferred = MacClippySourceAppSearch.preferredDisplayName(stored: storedName, resolved: nil)
                let displayName = preferred ?? resolver?(bundleID)
                guard let needle = String.fromDatabaseValue(values[2]) else { return false }
                return MacClippySourceAppSearch.segments(bundleID: bundleID, displayName: displayName)
                    .contains { $0.localizedCaseInsensitiveContains(needle) }
            })
            for value in filter.sourceAppContains {
                predicates.append("macclippy_source_app_contains(source_app, source_app_name, ?)")
                rawArguments.append(value)
            }
        }
        if !filter.labelContains.isEmpty {
            connection.add(function: DatabaseFunction("macclippy_label_contains", argumentCount: 2) { values in
                guard let label = String.fromDatabaseValue(values[0]),
                      let needle = String.fromDatabaseValue(values[1]) else { return false }
                return label.localizedCaseInsensitiveContains(needle)
            })
            for value in filter.labelContains {
                predicates.append("macclippy_label_contains(custom_label, ?)")
                rawArguments.append(value)
            }
        }
        return (predicates, rawArguments)
    }

    public func list(
        limit: Int,
        offset: Int = 0,
        contentKind: MacClippyContentKind? = nil,
        filter: MacClippyClipboardMetadataFilter? = nil,
        requiresURL: Bool = false,
        before cursor: MacClippyClipboardHistoryCursor? = nil
    ) throws -> [ClipboardItemMeta] {
        guard limit > 0 else { return [] }
        return try database.queue.read { connection in
            var predicates: [String] = []
            var rawArguments: [Any] = []
            let activeFilter = filter ?? MacClippyClipboardMetadataFilter(contentKind: contentKind)
            Self.appendFilterPredicates(
                activeFilter,
                requiresURL: requiresURL,
                predicates: &predicates,
                rawArguments: &rawArguments,
                on: connection
            )
            if let cursor {
                predicates.append("(modified < ? OR (modified = ? AND lamport < ?) OR (modified = ? AND lamport = ? AND id < ?))")
                let milliseconds = Self.milliseconds(cursor.modified)
                rawArguments += [milliseconds, milliseconds, Int64(cursor.lamport), milliseconds, Int64(cursor.lamport), cursor.id.rawValue]
            }

            var sql = """
                SELECT id, created, modified, device_id, lamport, kind, content_kind, preview, source_app,
                       source_app_name, frequency, last_accessed, custom_label, detected_type, ocr_text
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
                       source_app_name, frequency, last_accessed, custom_label, detected_type, ocr_text
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
    private static func appendFilterPredicates(
        _ filter: MacClippyClipboardMetadataFilter,
        requiresURL: Bool,
        predicates: inout [String],
        rawArguments: inout [Any],
        on connection: Database
    ) {
        if let contentKind = filter.contentKind {
            predicates.append("content_kind = ?")
            rawArguments.append(contentKind.rawValue)
        }
        for value in filter.sourceAppContains {
            predicates.append(
                """
                (
                    LOWER(IFNULL(source_app, '')) LIKE LOWER(?) ESCAPE '\\'
                    OR LOWER(IFNULL(source_app_name, '')) LIKE LOWER(?) ESCAPE '\\'
                )
                """
            )
            let pattern = likePattern(for: value)
            rawArguments.append(pattern)
            rawArguments.append(pattern)
        }
        for value in filter.labelContains {
            predicates.append("LOWER(custom_label) LIKE LOWER(?) ESCAPE '\\'")
            rawArguments.append(likePattern(for: value))
        }
        if filter.requiresLabel {
            predicates.append("custom_label IS NOT NULL AND trim(custom_label) != ''")
        }
        if filter.requiresOCR {
            predicates.append("ocr_text IS NOT NULL AND trim(ocr_text) != ''")
        }
        if requiresURL {
            registerURLMatch(on: connection)
            predicates.append("macclippy_record_is_url(detected_type, preview)")
        }
        for date in filter.modifiedBefore {
            predicates.append("modified < ?")
            rawArguments.append(milliseconds(date))
        }
        for date in filter.modifiedAfter {
            predicates.append("modified >= ?")
            rawArguments.append(milliseconds(date))
        }
    }

    private static func registerURLMatch(on connection: Database) {
        connection.add(function: DatabaseFunction("macclippy_record_is_url", argumentCount: 2) { values in
            if let detected = String.fromDatabaseValue(values[0]),
               detected.localizedCaseInsensitiveContains("url") { return true }
            guard let preview = String.fromDatabaseValue(values[1]) else { return false }
            return MacClippySmartText.matchesURL(preview)
        })
    }
}
