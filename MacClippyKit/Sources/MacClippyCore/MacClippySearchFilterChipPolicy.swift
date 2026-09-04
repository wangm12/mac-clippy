import Foundation

public struct MacClippySearchFilterChip: Equatable, Sendable, Identifiable {
    public var id: String { "\(token)|\(isSuggestion)" }
    public let token: String
    public let title: String
    public let isSuggestion: Bool

    public init(token: String, title: String, isSuggestion: Bool) {
        self.token = token
        self.title = title
        self.isSuggestion = isSuggestion
    }
}

/// Turns structured search clauses into removable chips and rebuilds the
/// query string from the existing grammar. Bare terms stay in the field and
/// are the OCR / card highlight needles.
public enum MacClippySearchFilterChipPolicy {
    public static let suggestedCatalog: [MacClippySearchFilterChip] = [
        MacClippySearchFilterChip(token: "type:text", title: "Text", isSuggestion: true),
        MacClippySearchFilterChip(token: "type:image", title: "Image", isSuggestion: true),
        MacClippySearchFilterChip(token: "type:url", title: "URL", isSuggestion: true),
        MacClippySearchFilterChip(token: "type:files", title: "Files", isSuggestion: true),
        MacClippySearchFilterChip(token: "has:ocr", title: "Has OCR", isSuggestion: true),
    ]

    public static func chips(
        from query: MacClippySearchGrammar.Query,
        calendar: Calendar = .current
    ) -> [MacClippySearchFilterChip] {
        query.clauses.compactMap { clause in
            guard clause.isStructured else { return nil }
            return MacClippySearchFilterChip(
                token: token(for: clause, calendar: calendar),
                title: title(for: clause, calendar: calendar),
                isSuggestion: false
            )
        }
    }

    public static func suggestions(
        for query: MacClippySearchGrammar.Query,
        calendar: Calendar = .current
    ) -> [MacClippySearchFilterChip] {
        let applied = Set(chips(from: query, calendar: calendar).map(\.token))
        return suggestedCatalog.filter { !applied.contains($0.token) }
    }

    public static func ocrHighlightTerms(from query: MacClippySearchGrammar.Query) -> [String] {
        query.bareTerms
    }

    public static func removing(
        token: String,
        from raw: String,
        calendar: Calendar = .current
    ) -> String {
        let parsed = MacClippySearchGrammar.parse(raw)
        let remaining = parsed.clauses.filter { self.token(for: $0, calendar: calendar) != token }
        guard remaining.count != parsed.clauses.count else { return raw }
        return serialize(
            MacClippySearchGrammar.Query(bareTerms: parsed.bareTerms, clauses: remaining),
            calendar: calendar
        )
    }

    public static func appending(
        token: String,
        to raw: String,
        calendar: Calendar = .current
    ) -> String {
        let parsed = MacClippySearchGrammar.parse(raw)
        if parsed.clauses.contains(where: { self.token(for: $0, calendar: calendar) == token }) {
            return raw
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? token : "\(trimmed) \(token)"
    }

    public static func serialize(
        _ query: MacClippySearchGrammar.Query,
        calendar: Calendar = .current
    ) -> String {
        let parts = query.bareTerms.map(quotedIfNeeded) + query.clauses.map {
            token(for: $0, calendar: calendar)
        }
        return parts.joined(separator: " ")
    }

    public static func ocrHitSnippet(
        ocrText: String?,
        terms: [String],
        maxLength: Int = 80
    ) -> String? {
        guard let ocrText, !ocrText.isEmpty, !terms.isEmpty else { return nil }
        let ranges = MacClippySearchQuery.highlightedRanges(in: ocrText, queryTerms: terms)
        guard let first = ranges.first else { return nil }
        if ocrText.count <= maxLength {
            return ocrText
        }

        let matchStart = ocrText.distance(from: ocrText.startIndex, to: first.lowerBound)
        let matchLength = ocrText.distance(from: first.lowerBound, to: first.upperBound)
        let leading = max(0, matchStart - max(0, (maxLength - matchLength) / 4))
        let trailing = min(ocrText.count, leading + maxLength)
        let start = ocrText.index(ocrText.startIndex, offsetBy: leading)
        let end = ocrText.index(ocrText.startIndex, offsetBy: trailing)
        var snippet = String(ocrText[start..<end])
        if leading > 0 {
            snippet = "…" + snippet
        }
        if trailing < ocrText.count {
            snippet += "…"
        }
        return snippet
    }

    public static func token(
        for clause: MacClippySearchGrammar.Clause,
        calendar: Calendar = .current
    ) -> String {
        switch clause {
        case .bare(let term):
            return quotedIfNeeded(term)
        case .type(let kind):
            return "type:\(kind.rawValue)"
        case .app(let value):
            return "app:\(quotedIfNeeded(value))"
        case .label(let value):
            return "name:\(quotedIfNeeded(value))"
        case .hasLabel:
            return "has:name"
        case .hasOCR:
            return "has:ocr"
        case .before(let date):
            return "before:\(dayToken(date, calendar: calendar))"
        case .after(let date):
            return "after:\(dayToken(date, calendar: calendar))"
        case .url:
            return "type:url"
        }
    }

    private static func title(
        for clause: MacClippySearchGrammar.Clause,
        calendar: Calendar
    ) -> String {
        switch clause {
        case .bare(let term):
            return term
        case .type(let kind):
            return title(for: kind)
        case .app(let value):
            return value
        case .label(let value):
            return value
        case .hasLabel:
            return "Has name"
        case .hasOCR:
            return "Has OCR"
        case .before(let date):
            return "Before \(dayToken(date, calendar: calendar))"
        case .after(let date):
            return "After \(dayToken(date, calendar: calendar))"
        case .url:
            return "URL"
        }
    }

    private static func title(for kind: MacClippyContentKind) -> String {
        switch kind {
        case .text: return "Text"
        case .rtf: return "RTF"
        case .html: return "HTML"
        case .image: return "Image"
        case .files: return "Files"
        }
    }

    private static func quotedIfNeeded(_ value: String) -> String {
        if value.contains(where: { $0.isWhitespace || $0 == "\"" }) {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return value
    }

    private static func dayToken(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
