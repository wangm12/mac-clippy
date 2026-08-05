import Foundation

// P2b: a pure, Foundation-only structured search grammar layered over the
// existing clipboard metadata. This file adds NO new storage: it only parses a
// query string into typed clauses and evaluates those clauses against a
// MacClippySearchRecord built from the existing ClipboardItemMeta fields
// (contentKind, sourceAppBundleID, customLabel, ocrText, modified). Bare
// free-text terms are NOT evaluated here; they are returned to the caller so
// the existing FTS5 search index keeps its behavior. Structured clauses and
// bare terms are ANDed at the runtime layer.
//
// Safety rules encoded here:
// - Unknown or malformed clauses (unknown key, empty value, unparseable date)
//   are NOT silently dropped and NOT treated as match-all. They degrade to a
//   bare free-text term so the query narrows via FTS instead of broadening.
// - Quoted values (tag:"project alpha") are accepted; the surrounding quotes
//   are stripped and embedded escaped quotes are handled.
// - Dates are parsed with the current local calendar so a malformed date
//   never crashes; an invalid date degrades the clause to a bare term.

public enum MacClippySearchGrammar {
    // A single typed clause. `bare` carries a free-text term that the caller
    // forwards to the existing FTS index; the remaining cases are structured
    // predicates evaluated against MacClippySearchRecord.
    public enum Clause: Equatable, Sendable {
        case bare(String)
        case type(MacClippyContentKind)
        case app(String)
        case label(String)
        case hasLabel
        case hasOCR
        case before(Date)
        case after(Date)
    }

    public struct Query: Equatable, Sendable {
        public let bareTerms: [String]
        public let clauses: [Clause]

        public init(bareTerms: [String] = [], clauses: [Clause] = []) {
            self.bareTerms = bareTerms
            self.clauses = clauses
        }

        // True when the query contains at least one structured clause. Used by
        // the runtime to decide whether to apply the predicate after FTS.
        public var hasStructuredClauses: Bool {
            clauses.contains { $0.isStructured }
        }

        // True when the query has structured clauses AND no bare free-text
        // terms. The runtime uses this to fetch all metas and filter them,
        // rather than seeding from an FTS query, so structured-only queries
        // work and fill the result limit.
        public var isStructuredOnly: Bool {
            hasStructuredClauses && bareTerms.isEmpty
        }
    }

    // The subset of clipboard metadata the predicate needs. The runtime
    // builds this from ClipboardItemMeta plus the contentKind it already
    // resolves when reading the body for entry(for:). Keeping this separate
    // from ClipboardItemMeta avoids adding a stored contentKind field to the
    // persisted model (the content kind lives on the clipboard record body).
    public struct SearchRecord: Equatable, Sendable {
        public let contentKind: MacClippyContentKind
        public let sourceAppBundleID: String?
        public let customLabel: String?
        public let ocrText: String?
        public let modified: Date

        public init(
            contentKind: MacClippyContentKind,
            sourceAppBundleID: String?,
            customLabel: String?,
            ocrText: String?,
            modified: Date
        ) {
            self.contentKind = contentKind
            self.sourceAppBundleID = sourceAppBundleID
            self.customLabel = customLabel
            self.ocrText = ocrText
            self.modified = modified
        }

        public init(meta: ClipboardItemMeta, contentKind: MacClippyContentKind) {
            self.contentKind = contentKind
            self.sourceAppBundleID = meta.sourceAppBundleID
            self.customLabel = meta.customLabel
            self.ocrText = meta.ocrText
            self.modified = meta.modified
        }
    }

    // Parse a raw query string into a Query. Whitespace-only input yields an
    // empty Query. Tokenization respects double-quoted values so a clause
    // value may contain spaces. Unknown keys and malformed values (empty
    // value, unparseable date) degrade to a bare term so the query narrows
    // via FTS instead of broadening to match-all.
    public static func parse(_ raw: String) -> Query {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Query() }

        var bareTerms: [String] = []
        var clauses: [Clause] = []
        var index = trimmed.startIndex

        while index < trimmed.endIndex {
            // Skip leading whitespace between tokens.
            while index < trimmed.endIndex, trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }
            guard index < trimmed.endIndex else { break }

            // Read one token, honoring double-quoted runs. A token may be a
            // bare term, a key:value clause, or a quoted value. Quoted runs
            // may appear at the start or after a key prefix and may contain
            // spaces.
            let tokenEnd = scanToken(in: trimmed, from: index)
            let token = String(trimmed[index..<tokenEnd])
            index = tokenEnd

            if let clause = parseClause(token) {
                switch clause {
                case .bare(let term):
                    if !term.isEmpty { bareTerms.append(term) }
                default:
                    clauses.append(clause)
                }
            }
        }

        return Query(bareTerms: bareTerms, clauses: clauses)
    }

    // Scan one token starting at `from`. Returns the end index of the token
    // (exclusive). A quote may appear at the start of the token OR mid-token
    // after a key prefix (e.g. tag:"project alpha"); in both cases the quoted
    // run may contain spaces and scanning continues through it until the
    // closing quote. An unterminated quote consumes the rest of the string
    // rather than crashing. Whitespace inside a quoted run is part of the
    // token; whitespace outside a quoted run ends the token.
    private static func scanToken(
        in source: String,
        from start: String.Index
    ) -> String.Index {
        var cursor = start
        while cursor < source.endIndex {
            let ch = source[cursor]
            if ch == "\\" {
                // Skip the escaped character so an embedded \" does not
                // terminate a quoted run.
                cursor = source.index(after: cursor)
                if cursor < source.endIndex {
                    cursor = source.index(after: cursor)
                }
                continue
            }
            if ch == "\"" {
                cursor = source.index(after: cursor)
                // Continue the quoted run until the next unescaped closing
                // quote. The opening quote is consumed; the closing quote is
                // consumed below, after which the loop resumes normal scanning
                // so a token like tag:"a b" ends right after the closing
                // quote (at the following whitespace or end of string).
                while cursor < source.endIndex {
                    let inner = source[cursor]
                    if inner == "\\" {
                        cursor = source.index(after: cursor)
                        if cursor < source.endIndex {
                            cursor = source.index(after: cursor)
                        }
                        continue
                    }
                    if inner == "\"" {
                        cursor = source.index(after: cursor)
                        break
                    }
                    cursor = source.index(after: cursor)
                }
                continue
            }
            if ch.isWhitespace {
                return cursor
            }
            cursor = source.index(after: cursor)
        }
        return source.endIndex
    }

    // Parse a single token into a Clause. Returns nil for an empty token. A
    // token without a colon is a bare term so it flows into FTS unchanged;
    // surrounding quotes are stripped via unquote. A token with a colon is
    // parsed as key:value; the value is unquoted if it was quoted. A malformed
    // value (e.g. an unterminated quote) degrades the whole token to a bare
    // term per the malformed-clause safety rule.
    private static func parseClause(_ token: String) -> Clause? {
        guard !token.isEmpty else { return nil }

        // A key:value clause requires a colon. A token without a colon is a
        // bare term so it flows into FTS unchanged. Strip surrounding quotes
        // so a quoted multi-word phrase is forwarded to FTS as one term. A
        // malformed (unterminated) quote degrades to a bare term.
        guard let colon = token.firstIndex(of: ":") else {
            guard let unquoted = unquote(token) else { return .bare(token) }
            return .bare(unquoted)
        }
        let key = token[..<colon]
        let value = String(token[token.index(after: colon)...])

        // An empty key (e.g. ":foo") is not a recognized clause; degrade to a
        // bare term so the query narrows rather than broadens.
        let keyString = String(key)
        if keyString.isEmpty {
            return .bare(token)
        }

        switch keyString {
        case "type":
            // Allow an optional quoted kind (type:"text") in addition to the
            // bare form (type:text).
            let kindValue = unquote(value) ?? value
            if let kind = MacClippyContentKind(rawValue: kindValue) {
                return .type(kind)
            }
            // Unknown content kind: degrade to a bare term so the query does
            // not silently broaden to match-all.
            return .bare(token)

        case "app":
            guard let cleaned = unquote(value) else { return .bare(token) }
            // An empty app value is not a usable clause; degrade to a bare
            // term so "app:" alone does not match everything.
            return cleaned.isEmpty ? .bare(token) : .app(cleaned)

        case "tag", "label":
            guard let cleaned = unquote(value) else { return .bare(token) }
            return cleaned.isEmpty ? .bare(token) : .label(cleaned)

        case "has":
            switch value {
            case "label": return .hasLabel
            case "ocr": return .hasOCR
            default:
                // Unknown has:<x>: degrade to a bare term.
                return .bare(token)
            }

        case "before":
            let dateValue = unquote(value) ?? value
            if let date = parseDayStart(dateValue) {
                return .before(date)
            }
            return .bare(token)

        case "after":
            let dateValue = unquote(value) ?? value
            if let date = parseDayStart(dateValue) {
                return .after(date)
            }
            return .bare(token)

        default:
            // Unknown key: degrade to a bare term so "foo:bar" still narrows
            // via FTS instead of being dropped or broadening the query.
            return .bare(token)
        }
    }

    // Strip surrounding quotes from a value and unescape embedded \" sequences.
    // A value with no surrounding quotes is returned as-is. A value that
    // starts with a quote but has no matching closing quote is treated as
    // malformed and returns nil so the caller can degrade the whole token to a
    // bare term (per the malformed-clause safety rule) instead of producing a
    // clause with a stray quote in its value.
    private static func unquote(_ value: String) -> String? {
        guard value.hasPrefix("\"") else { return value }
        // Need at least a closing quote after the opening one.
        guard value.count >= 2, value.hasSuffix("\"") else { return nil }
        var inner = String(value.dropFirst().dropLast())
        inner = inner.replacingOccurrences(of: "\\\"", with: "\"")
        return inner
    }

    // Parse a YYYY-MM-DD value as the start of that day in the current local
    // calendar. Returns nil for an invalid date so the caller can degrade the
    // clause to a bare term instead of crashing. Uses the autoupdating current
    // calendar so local-day semantics match how the UI presents dates.
    private static func parseDayStart(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 10 else { return nil }
        let chars = Array(trimmed)
        guard chars[4] == "-", chars[7] == "-" else { return nil }
        let parts = trimmed.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }

        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let components = DateComponents(year: year, month: month, day: day, hour: 0, minute: 0, second: 0)
        // Strict date validation: Calendar.date(from:) tolerates overflow
        // (e.g. day 32 wraps into the next month), so round-trip the resolved
        // date and compare the components to reject invalid day/month
        // combinations without ever crashing.
        guard let date = calendar.date(from: components) else { return nil }
        let roundTripped = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTripped.year == year,
              roundTripped.month == month,
              roundTripped.day == day else { return nil }
        return date
    }

    // Evaluate the structured clauses of a Query against a record. Bare terms
    // are intentionally NOT evaluated here; they are handled by the FTS layer
    // at the runtime. Returns true when every structured clause matches.
    public static func matches(_ query: Query, record: SearchRecord) -> Bool {
        for clause in query.clauses where clause.isStructured {
            if !matches(clause, record: record) { return false }
        }
        return true
    }

    // Evaluate a single structured clause against a record. Public so tests
    // can assert individual clauses without composing a full Query.
    public static func matches(_ clause: Clause, record: SearchRecord) -> Bool {
        switch clause {
        case .bare:
            // Bare terms are evaluated by the FTS layer, not here. A bare
            // clause is never a structured predicate, so it always matches
            // here and does not narrow the predicate.
            return true
        case .type(let kind):
            return record.contentKind == kind
        case .app(let value):
            return record.sourceAppBundleID?.localizedCaseInsensitiveContains(value) ?? false
        case .label(let value):
            return record.customLabel?.localizedCaseInsensitiveContains(value) ?? false
        case .hasLabel:
            let trimmed = record.customLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false
        case .hasOCR:
            let trimmed = record.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false
        case .before(let dayStart):
            // before:<day> means modified strictly before the start of that
            // day; a record modified earlier the same calendar day is NOT
            // included (it is >= the start).
            return record.modified < dayStart
        case .after(let dayStart):
            // after:<day> means modified on or after the start of that day.
            return record.modified >= dayStart
        }
    }
}

public extension MacClippySearchGrammar.Clause {
    // True for clauses that are structured predicates (everything except
    // .bare). Used to distinguish FTS-bound terms from predicate clauses.
    var isStructured: Bool {
        switch self {
        case .bare: return false
        default: return true
        }
    }
}
