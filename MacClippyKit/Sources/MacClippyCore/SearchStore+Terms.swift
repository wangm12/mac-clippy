import Foundation
import GRDB

extension MacClippySearchStore {
    /// Substring pages continue by rowid and stamp this rank on the cursor so
    /// a later page does not restart the prefix MATCH pass.
    private static let substringRank: Double = 1

    public func search(
        kind: RecordKind? = .clipboardItem,
        terms: [String],
        limit: Int,
        after cursor: MacClippySearchCursor? = nil
    ) throws -> [SearchHit] {
        let normalized = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty, limit > 0 else { return [] }
        let cjkTerms = MacClippySearchQuery.cjkTerms(in: normalized)
        let ftsTerms = MacClippySearchQuery.ftsTerms(in: normalized)
        let infixTerms = MacClippySearchQuery.infixTerms(in: normalized)
        let asciiInfixTerms = infixTerms.filter { !MacClippySearchQuery.containsCJK($0) }
        if ftsTerms.isEmpty {
            return try substringSearch(kind: kind, terms: cjkTerms, limit: limit, after: cursor)
        }
        if asciiInfixTerms.isEmpty {
            return try matchRawFTS(
                kind: kind,
                query: MacClippySearchQuery.ftsMatchQuery(from: ftsTerms),
                likePatterns: MacClippySearchQuery.likePatterns(for: cjkTerms),
                limit: limit,
                after: cursor
            )
        }
        return try searchPrefixThenInfix(
            kind: kind,
            ftsTerms: ftsTerms,
            cjkTerms: cjkTerms,
            infixTerms: infixTerms,
            asciiInfixTerms: asciiInfixTerms,
            limit: limit,
            after: cursor
        )
    }

    private func searchPrefixThenInfix(
        kind: RecordKind?,
        ftsTerms: [String],
        cjkTerms: [String],
        infixTerms: [String],
        asciiInfixTerms: [String],
        limit: Int,
        after cursor: MacClippySearchCursor?
    ) throws -> [SearchHit] {
        let prefixQuery = MacClippySearchQuery.ftsMatchQuery(from: ftsTerms)
        let cjkPatterns = MacClippySearchQuery.likePatterns(for: cjkTerms)
        let prefixHits: [SearchHit]
        if isSubstringCursor(cursor) {
            prefixHits = []
        } else {
            prefixHits = try matchRawFTS(
                kind: kind,
                query: prefixQuery,
                likePatterns: cjkPatterns,
                limit: limit,
                after: cursor
            )
            if prefixHits.count >= limit {
                return prefixHits
            }
        }

        let matchOnlyTerms = ftsTerms.filter { term in
            !asciiInfixTerms.contains(term)
        }
        let matchOnlyQuery = MacClippySearchQuery.ftsMatchQuery(from: matchOnlyTerms)
        let infixHits = try substringSearch(
            kind: kind,
            terms: infixTerms,
            matchQuery: matchOnlyQuery.isEmpty ? nil : matchOnlyQuery,
            excludingMatchQuery: prefixQuery,
            excludingLikePatterns: cjkPatterns,
            limit: limit - prefixHits.count,
            after: isSubstringCursor(cursor) ? cursor : nil
        )
        return prefixHits + infixHits
    }

    private func isSubstringCursor(_ cursor: MacClippySearchCursor?) -> Bool {
        cursor?.rank == Self.substringRank
    }

    private func matchRawFTS(
        kind: RecordKind?,
        query: String,
        likePatterns: [String] = [],
        limit: Int,
        after cursor: MacClippySearchCursor?
    ) throws -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        return try database.queue.read { connection in
            var sql = """
                SELECT kind, record_id,
                       snippet(macclippy_search_index, 2, char(30), char(31), '...', 12) AS snippet,
                       rank AS search_rank,
                       macclippy_search_index.rowid AS search_rowid
                FROM macclippy_search_index
                WHERE macclippy_search_index MATCH ?
            """
            var arguments: [Any] = [query]
            if let kind {
                sql += " AND kind = ?"
                arguments.append(kind.rawValue)
            }
            for pattern in likePatterns {
                sql += " AND content LIKE ? ESCAPE '\\'"
                arguments.append(pattern)
            }
            if let cursor {
                sql += " AND (rank > ? OR (rank = ? AND macclippy_search_index.rowid > ?))"
                arguments += [cursor.rank, cursor.rank, cursor.rowID]
            }
            sql += " ORDER BY rank ASC, macclippy_search_index.rowid ASC LIMIT ?"
            arguments.append(limit)
            guard let statementArguments = StatementArguments(arguments) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return try Row.fetchAll(connection, sql: sql, arguments: statementArguments).map { row in
                guard let kind = RecordKind(rawValue: row["kind"]),
                      let id = RecordID(rawValue: row["record_id"]),
                      let rank: Double = row["search_rank"],
                      let rowID: Int64 = row["search_rowid"] else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return SearchHit(kind: kind, id: id, snippet: row["snippet"], rank: rank, rowID: rowID)
            }
        }
    }

    private func substringSearch(
        kind: RecordKind?,
        terms: [String],
        matchQuery: String? = nil,
        excludingMatchQuery: String? = nil,
        excludingLikePatterns: [String] = [],
        limit: Int,
        after cursor: MacClippySearchCursor?
    ) throws -> [SearchHit] {
        let patterns = MacClippySearchQuery.likePatterns(for: terms)
        return try database.queue.read { connection in
            var sql = """
                SELECT kind, record_id, content,
                       macclippy_search_index.rowid AS search_rowid
                FROM macclippy_search_index
                WHERE 1 = 1
            """
            var arguments: [Any] = []
            if let kind {
                sql += " AND kind = ?"
                arguments.append(kind.rawValue)
            }
            if let matchQuery, !matchQuery.isEmpty {
                sql += " AND macclippy_search_index MATCH ?"
                arguments.append(matchQuery)
            }
            for pattern in patterns {
                sql += " AND content LIKE ? ESCAPE '\\'"
                arguments.append(pattern)
            }
            if let excludingMatchQuery, !excludingMatchQuery.isEmpty {
                sql += """
                     AND macclippy_search_index.rowid NOT IN (
                        SELECT rowid FROM macclippy_search_index
                        WHERE macclippy_search_index MATCH ?
                    """
                arguments.append(excludingMatchQuery)
                if let kind {
                    sql += " AND kind = ?"
                    arguments.append(kind.rawValue)
                }
                for pattern in excludingLikePatterns {
                    sql += " AND content LIKE ? ESCAPE '\\'"
                    arguments.append(pattern)
                }
                sql += ")"
            }
            if let cursor {
                sql += " AND macclippy_search_index.rowid > ?"
                arguments.append(cursor.rowID)
            }
            sql += " ORDER BY macclippy_search_index.rowid ASC LIMIT ?"
            arguments.append(limit)
            guard let statementArguments = StatementArguments(arguments) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return try Row.fetchAll(connection, sql: sql, arguments: statementArguments).map { row in
                guard let kind = RecordKind(rawValue: row["kind"]),
                      let id = RecordID(rawValue: row["record_id"]),
                      let content: String = row["content"],
                      let rowID: Int64 = row["search_rowid"] else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return SearchHit(
                    kind: kind,
                    id: id,
                    snippet: Self.substringSnippet(content, terms: terms),
                    rank: Self.substringRank,
                    rowID: rowID
                )
            }
        }
    }

    private static func substringSnippet(_ content: String, terms: [String]) -> String {
        let haystack = content
        let needle = terms.first { MacClippySearchQuery.containsCJK($0) } ?? terms.first ?? ""
        guard !needle.isEmpty,
              let found = haystack.range(of: needle, options: .caseInsensitive) else {
            return String(haystack.prefix(80))
        }
        let start = haystack.index(found.lowerBound, offsetBy: -24, limitedBy: haystack.startIndex)
            ?? haystack.startIndex
        let end = haystack.index(found.upperBound, offsetBy: 24, limitedBy: haystack.endIndex)
            ?? haystack.endIndex
        var snippet = String(haystack[start..<end])
        if start != haystack.startIndex { snippet = "..." + snippet }
        if end != haystack.endIndex { snippet += "..." }
        return snippet
    }
}
