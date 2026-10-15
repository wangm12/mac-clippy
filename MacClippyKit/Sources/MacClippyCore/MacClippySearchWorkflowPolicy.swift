import Foundation

/// UI filters compose the existing grammar; focus never owns their lifetime.
public enum MacClippySearchWorkflowPolicy {
    public enum Group: Sendable {
        case contentType, source, before, after
    }

    public enum DateFilterError: Error, Equatable {
        case invalidDate
    }

    /// The filter form accepts one date, while the main search grammar stays
    /// tolerant of malformed tokens and supports multiple conditions.
    public static func dateClause(
        _ input: String, for group: Group
    ) throws -> MacClippySearchGrammar.Clause? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else {
            throw DateFilterError.invalidDate
        }
        let prefix: String
        switch group {
        case .before: prefix = "before"
        case .after: prefix = "after"
        default: throw DateFilterError.invalidDate
        }
        let parsed = MacClippySearchGrammar.parse("\(prefix):\(value)")
        guard parsed.bareTerms.isEmpty, parsed.clauses.count == 1,
              let clause = parsed.clauses.first, belongs(clause, to: group) else {
            throw DateFilterError.invalidDate
        }
        return clause
    }

    public static func keywords(in raw: String) -> String {
        MacClippySearchGrammar.rawKeywords(in: raw)
    }

    public static func clearingFilters(in raw: String) -> String {
        keywords(in: raw)
    }

    /// Incomplete quoted/escaped text must not absorb mounted conditions.
    /// Keep the user's lexical spelling and put filters before that draft.
    public static func composing(_ text: String, clauses: [MacClippySearchGrammar.Clause]) -> String {
        let filters = MacClippySearchFilterChipPolicy.serialize(.init(clauses: clauses))
        let parts = hasUnfinishedToken(text) ? [filters, text] : [text, filters]
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func replacing(
        _ group: Group,
        with replacement: MacClippySearchGrammar.Clause?,
        in raw: String
    ) -> String {
        let parsed = MacClippySearchGrammar.parse(raw)
        var clauses = parsed.clauses.filter { !belongs($0, to: group) }
        if let replacement { clauses.append(replacement) }
        return composing(keywords(in: raw), clauses: clauses)
    }

    private static func hasUnfinishedToken(_ value: String) -> Bool {
        var quoted = false
        var escaped = false
        for character in value {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" { escaped = true } else if character == "\"" { quoted.toggle() }
        }
        return quoted || escaped
    }

    private static func belongs(_ clause: MacClippySearchGrammar.Clause, to group: Group) -> Bool {
        switch (group, clause) {
        case (.contentType, .type), (.contentType, .url), (.source, .app),
            (.before, .before), (.after, .after):
            true
        default: false
        }
    }
}
