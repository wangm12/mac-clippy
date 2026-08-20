import Foundation

public enum MacClippySearchQuery {
    public static func ftsMatchQuery(from terms: [String]) -> String {
        terms.compactMap(ftsToken(for:)).joined(separator: " ")
    }

    public static func cjkTerms(in terms: [String]) -> [String] {
        terms.filter { containsCJK($0) }
    }

    public static func ftsTerms(in terms: [String]) -> [String] {
        terms.filter { !containsCJK($0) }
    }

    public static func containsCJK(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x3040...0x30FF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
        }
    }

    public static func likePatterns(for terms: [String]) -> [String] {
        terms.map { term in
            let escaped = term
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            return "%\(escaped)%"
        }
    }

    public static func displayText(fromFTSSnippet snippet: String) -> String {
        var output = ""
        output.reserveCapacity(snippet.count)
        var index = snippet.startIndex
        while index < snippet.endIndex {
            let character = snippet[index]
            if character == "\u{001E}",
               let closing = snippet[index...].firstIndex(of: "\u{001F}") {
                let innerStart = snippet.index(after: index)
                output.append(contentsOf: snippet[innerStart..<closing])
                index = snippet.index(after: closing)
                continue
            }
            if character == "<",
               let closing = snippet[index...].firstIndex(of: ">"),
               isLegacyFTSHighlight(snippet[snippet.index(after: index)..<closing]) {
                let innerStart = snippet.index(after: index)
                output.append(contentsOf: snippet[innerStart..<closing])
                index = snippet.index(after: closing)
                continue
            }
            output.append(character)
            index = snippet.index(after: index)
        }
        return output
    }

    private static func isLegacyFTSHighlight(_ inner: Substring) -> Bool {
        !inner.isEmpty
            && inner.count <= 40
            && !inner.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "=" || $0 == "<" })
    }

    public static func allTerms(
        _ terms: [String],
        appearIn haystacks: [String]
    ) -> Bool {
        let needles = terms.compactMap { term -> String? in
            let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            return needle.isEmpty ? nil : needle
        }
        guard !needles.isEmpty else { return true }
        return needles.allSatisfy { needle in
            haystacks.contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    public static func highlightedRanges(
        in text: String,
        queryTerms: [String]
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        for term in queryTerms {
            let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            guard !needle.isEmpty else { continue }
            var searchStart = text.startIndex
            while let found = text.range(
                of: needle,
                options: .caseInsensitive,
                range: searchStart..<text.endIndex
            ) {
                ranges.append(found)
                searchStart = found.upperBound
            }
        }
        return mergeOverlapping(ranges)
    }

    private static func mergeOverlapping(
        _ ranges: [Range<String.Index>]
    ) -> [Range<String.Index>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                let end = max(last.upperBound, range.upperBound)
                merged[merged.count - 1] = last.lowerBound..<end
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func ftsToken(for term: String) -> String? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("*"), trimmed.count > 1 {
            let stem = String(trimmed.dropLast())
            guard !stem.contains(where: \.isWhitespace) else {
                return quoted(trimmed)
            }
            return quoted(stem) + "*"
        }
        return quoted(trimmed)
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
