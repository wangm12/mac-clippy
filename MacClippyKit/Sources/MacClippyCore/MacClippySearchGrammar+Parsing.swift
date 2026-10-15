import Foundation

extension MacClippySearchGrammar {
    // Parse a raw query string into a Query. Whitespace-only input yields an
    // empty Query. Tokenization respects double-quoted values so a clause
    // value may contain spaces. Unknown keys and malformed values (empty
    // value, unparseable date) degrade to a bare term so the query narrows
    // via FTS instead of broadening to match-all.
    public static func parse(_ raw: String) -> Query {
        var bareTerms: [String] = []
        var clauses: [Clause] = []
        for token in tokens(in: raw) {
            guard let clause = parseClause(token) else { continue }
            switch clause {
            case .bare(let term):
                if !term.isEmpty { bareTerms.append(term) }
            default: clauses.append(clause)
            }
        }
        return Query(bareTerms: bareTerms, clauses: clauses)
    }

    /// Preserve lexical spelling when the UI temporarily removes filters.
    public static func rawKeywords(in raw: String) -> String {
        tokens(in: raw).filter {
            guard let clause = parseClause($0) else { return false }
            if case .bare = clause { return true }
            return false
        }.joined(separator: " ")
    }

    static func removingFilterToken(_ token: String, from raw: String, calendar: Calendar) -> String {
        tokens(in: raw).filter {
            guard let clause = parseClause($0) else { return true }
            return MacClippySearchFilterChipPolicy.token(for: clause, calendar: calendar) != token
        }.joined(separator: " ")
    }

    private static func tokens(in raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [String] = []
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            while index < trimmed.endIndex, trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }
            guard index < trimmed.endIndex else { break }
            let end = scanToken(in: trimmed, from: index)
            result.append(String(trimmed[index..<end]))
            index = end
        }
        return result
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
            let character = source[cursor]
            if character == "\\" {
                // Skip the escaped character so an embedded \" does not
                // terminate a quoted run.
                cursor = source.index(after: cursor)
                if cursor < source.endIndex {
                    cursor = source.index(after: cursor)
                }
                continue
            }
            if character == "\"" {
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
            if character.isWhitespace {
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

        return structuredClause(key: keyString, value: value, token: token)
    }

    private static func structuredClause(key: String, value: String, token: String) -> Clause {
        switch key {
        case "type":
            let kindValue = unquote(value) ?? value
            if let kind = MacClippyContentKind(rawValue: kindValue) { return .type(kind) }
            return urlOrBareClause(kindValue, token: token)
        case "app", "name", "tag", "label":
            return namedClause(key: key, value: value, token: token)
        case "has":
            return presenceClause(value: value, token: token)
        case "before", "after":
            return dateClause(key: key, value: value, token: token)
        default: return .bare(token)
        }
    }

    private static func namedClause(key: String, value: String, token: String) -> Clause {
        guard let cleaned = unquote(value), !cleaned.isEmpty else { return .bare(token) }
        return key == "app" ? .app(cleaned) : .label(cleaned)
    }

    private static func presenceClause(value: String, token: String) -> Clause {
        switch value {
        case "name", "label": .hasLabel
        case "ocr": .hasOCR
        default: .bare(token)
        }
    }

    private static func dateClause(key: String, value: String, token: String) -> Clause {
        guard let date = parseDayStart(unquote(value) ?? value) else { return .bare(token) }
        return key == "before" ? .before(date) : .after(date)
    }

    private static func urlOrBareClause(_ kindValue: String, token: String) -> Clause {
        kindValue == "url" ? .url : .bare(token)
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
            let day = Int(parts[2])
        else { return nil }

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
            roundTripped.day == day
        else { return nil }
        return date
    }

}
