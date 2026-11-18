import Foundation

enum MacClippyPasteboardPrivacyHTML {
    struct Texts {
        let source: String
        let rendered: String
        let separated: String
        let collapsed: String
    }
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "Tab": "\t", "NewLine": "\n", "copy": "©", "reg": "®", "trade": "™", "cent": "¢",
        "pound": "£", "yen": "¥", "euro": "€", "sect": "§", "deg": "°", "plusmn": "±",
        "times": "×", "divide": "÷", "ndash": "–", "mdash": "—", "hellip": "…", "bull": "•",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "shy": "\u{AD}",
        "ZeroWidthSpace": "\u{200B}", "zwj": "\u{200D}", "zwnj": "\u{200C}", "colon": ":",
        "equals": "=", "sol": "/", "bsol": "\\", "lpar": "(", "rpar": ")", "commat": "@"
    ]

    /// No HTML importer, resource loading, JavaScript, or main-queue work.
    /// Unknown/malformed entities fail closed instead of guessing their text.
    static func texts(
        _ html: String, isWithinBudget: () -> Bool
    ) -> Texts? {
        let scalars = Array(html.unicodeScalars)
        var source = ""
        var rendered = ""
        var separated = ""
        var collapsed = ""
        var pendingBoundary = false
        var index = 0
        var inTag = false
        var quote: Unicode.Scalar?
        var iterations = 0
        while index < scalars.count {
            if iterations % 256 == 0 && !isWithinBudget() { return nil }
            iterations += 1
            let scalar = scalars[index]
            if scalar == "&" {
                guard let decoded = entity(scalars, index: &index) else { return nil }
                source += decoded
                if !inTag {
                    rendered += decoded
                    separated += decoded
                    appendCollapsed(decoded, to: &collapsed, pendingBoundary: &pendingBoundary)
                }
                continue
            }
            source.unicodeScalars.append(scalar)
            if inTag {
                updateTag(scalar, quote: &quote, inTag: &inTag)
            } else if scalar == "<" && startsTag(scalars, at: index + 1) {
                inTag = true
                // Retain a conservative spacing variant as well as joined
                // text. This covers br/block and inline CSS layout boundaries.
                separated += "\n"
                pendingBoundary = true
            } else {
                rendered.unicodeScalars.append(scalar)
                separated.unicodeScalars.append(scalar)
                appendCollapsed(String(scalar), to: &collapsed, pendingBoundary: &pendingBoundary)
            }
            index += 1
        }
        guard !inTag, isWithinBudget() else { return nil }
        finishCollapsed(&collapsed, pendingBoundary: pendingBoundary)
        return Texts(source: source, rendered: rendered, separated: separated, collapsed: collapsed)
    }

    private static func appendCollapsed(_ text: String, to output: inout String, pendingBoundary: inout Bool) {
        if pendingBoundary && !output.isEmpty && output.last != "\n" { output += "\n" }
        pendingBoundary = false
        output += text
    }

    private static func finishCollapsed(_ output: inout String, pendingBoundary: Bool) {
        if pendingBoundary && !output.isEmpty && output.last != "\n" { output += "\n" }
    }

    fileprivate static func updateTag(_ scalar: Unicode.Scalar, quote: inout Unicode.Scalar?, inTag: inout Bool) {
        if scalar == quote {
            quote = nil
        } else if quote == nil && (scalar == "\"" || scalar == "'") {
            quote = scalar
        } else if quote == nil && scalar == ">" {
            inTag = false
        }
    }

    private static func startsTag(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        guard index < scalars.count else { return false }
        let value = scalars[index].value
        return (65...90).contains(value) || (97...122).contains(value)
            || scalars[index] == "/" || scalars[index] == "!" || scalars[index] == "?"
    }

    private static func entity(_ scalars: [Unicode.Scalar], index: inout Int) -> String? {
        index += 1
        if index < scalars.count && scalars[index] == "#" { return numericEntity(scalars, index: &index) }
        let nameStart = index
        while index < scalars.count && CharacterSet.alphanumerics.contains(scalars[index]) {
            guard index - nameStart < 40 else { return nil }
            index += 1
        }
        guard index > nameStart else { return "&" }
        let name = String(String.UnicodeScalarView(scalars[nameStart..<index]))
        guard index < scalars.count && scalars[index] == ";" else {
            // HTML's ambiguous prefix rules must not silently alter a match.
            return namedEntities[name]
        }
        index += 1
        return namedEntities[name]
    }

    private static func numericEntity(_ scalars: [Unicode.Scalar], index: inout Int) -> String? {
        index += 1
        let hex = index < scalars.count && (scalars[index] == "x" || scalars[index] == "X")
        if hex { index += 1 }
        var value: UInt32 = 0
        var digits = 0
        while index < scalars.count, let digit = digit(scalars[index].value, hex: hex) {
            guard digits < 8 else { return nil }
            value = value * (hex ? 16 : 10) + digit
            digits += 1
            index += 1
        }
        guard digits > 0, value != 0, !(0x80...0x9F).contains(value),
              let scalar = Unicode.Scalar(value) else { return nil }
        if index < scalars.count && scalars[index] == ";" { index += 1 }
        return String(scalar)
    }

    private static let digitTable = "0123456789"
}

private struct PlainTextScanState {
    var output = ""
    var inTag = false
    var quote: Unicode.Scalar?
    var tagName = ""
    var capturingTagName = false
    var isClosingTag = false
    var pendingSpace = false
    var pendingNewline = false

    mutating func stepTagScalar(
        _ scalar: Unicode.Scalar,
        blockBreakTags: Set<String>,
        inlineSpaceTags: Set<String>
    ) {
        if capturingTagName {
            if scalar == "/" && tagName.isEmpty {
                isClosingTag = true
            } else if MacClippyPasteboardPrivacyHTML.isASCIILetterOrDigit(scalar) {
                tagName.unicodeScalars.append(scalar)
            } else {
                capturingTagName = false
            }
        }
        MacClippyPasteboardPrivacyHTML.updateTag(scalar, quote: &quote, inTag: &inTag)
        guard !inTag else { return }
        let lower = tagName.lowercased()
        if blockBreakTags.contains(lower) {
            pendingNewline = !output.isEmpty
        } else if (!isClosingTag && (lower == "td" || lower == "th")) || inlineSpaceTags.contains(lower) {
            pendingSpace = !output.isEmpty
        }
    }
}

extension MacClippyPasteboardPrivacyHTML {
    /// Pure-Swift HTML-to-plain-text extraction without WebKit/AppKit
    /// `NSAttributedString(html:)`, network resource fetches, or main-queue hops.
    static func plainText(from html: String) -> String {
        guard !html.isEmpty else { return "" }
        let scalars = Array(stripNonVisibleHTMLSections(html).unicodeScalars)
        var state = PlainTextScanState()
        state.output.reserveCapacity(min(scalars.count, 4_096))
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            if state.inTag {
                state.stepTagScalar(scalar, blockBreakTags: blockBreakTags, inlineSpaceTags: inlineSpaceTags)
                index += 1
                continue
            }
            if scalar == "&" {
                var probe = index
                if let decoded = entity(scalars, index: &probe) {
                    index = probe
                    appendExtractedFragment(
                        decoded,
                        to: &state.output,
                        pendingSpace: &state.pendingSpace,
                        pendingNewline: &state.pendingNewline
                    )
                    continue
                }
            }
            if scalar == "<" && startsTag(scalars, at: index + 1) {
                state.inTag = true
                state.quote = nil
                state.tagName = ""
                state.capturingTagName = true
                state.isClosingTag = false
            } else if scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar == " " {
                if !state.output.isEmpty { state.pendingSpace = true }
            } else {
                appendExtractedScalar(
                    scalar,
                    to: &state.output,
                    pendingSpace: &state.pendingSpace,
                    pendingNewline: &state.pendingNewline
                )
            }
            index += 1
        }
        return state.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bounds HTML size and removes scripts/frames/external subresource URLs
    /// before passing rich HTML to AppKit's attributed preview importer.
    static func sanitizedHTMLForAttributedPreview(
        _ html: String,
        maxUTF8Bytes: Int = 262_144
    ) -> String {
        var result = boundedPrefix(html, maxUTF8Bytes: maxUTF8Bytes)
        for pattern in previewUnsafeBlockPatterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        let remoteURLPattern =
            #"(?i)\b(?:src|poster|background)\s*=\s*"#
            + #"(?:"(?:https?:)?//[^"]*"|'(?:https?:)?//[^']*'|[^\s>]*//[^\s>]*)"#
        let replacements = [
            (remoteURLPattern, ""),
            (#"(?i)url\(\s*["']?(?:https?:)?//[^)]*\)"#, "url()"),
            (#"(?i)\bon[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]*)"#, "")
        ]
        for (pattern, replacement) in replacements {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    private static let blockBreakTags: Set<String> = [
        "p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
        "blockquote", "pre", "hr", "section", "article", "header", "footer", "ul", "ol"
    ]

    private static let inlineSpaceTags: Set<String> = ["img", "svg"]

    private static let previewUnsafeBlockPatterns: [String] = [
        #"<script\b[^>]*>[\s\S]*?</script>"#,
        #"<iframe\b[^>]*>[\s\S]*?</iframe>"#,
        #"<object\b[^>]*>[\s\S]*?</object>"#,
        #"<embed\b[^>]*>"#,
        #"<link\b[^>]*>"#,
        #"<base\b[^>]*>"#,
        #"<meta\b[^>]*>"#
    ]

    private static func stripNonVisibleHTMLSections(_ html: String) -> String {
        var result = html
        let patterns = [
            #"<!--[\s\S]*?-->"#,
            #"<script\b[^>]*>[\s\S]*?</script>"#,
            #"<style\b[^>]*>[\s\S]*?</style>"#,
            #"<head\b[^>]*>[\s\S]*?</head>"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    private static func boundedPrefix(_ string: String, maxUTF8Bytes: Int) -> String {
        guard string.utf8.count > maxUTF8Bytes else { return string }
        var endIndex = string.utf8.index(string.utf8.startIndex, offsetBy: maxUTF8Bytes)
        while endIndex > string.utf8.startIndex {
            if let value = String(bytes: string.utf8[..<endIndex], encoding: .utf8) {
                return value
            }
            endIndex = string.utf8.index(before: endIndex)
        }
        return ""
    }

    fileprivate static func isASCIILetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        let scalarValue = scalar.value
        return (65...90).contains(scalarValue)
            || (97...122).contains(scalarValue)
            || (48...57).contains(scalarValue)
    }

    private static func appendExtractedFragment(
        _ fragment: String,
        to output: inout String,
        pendingSpace: inout Bool,
        pendingNewline: inout Bool
    ) {
        for scalar in fragment.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                if !output.isEmpty { pendingNewline = true }
            } else if scalar == " " || scalar == "\t" || scalar == "\u{A0}" {
                if !output.isEmpty { pendingSpace = true }
            } else {
                appendExtractedScalar(
                    scalar,
                    to: &output,
                    pendingSpace: &pendingSpace,
                    pendingNewline: &pendingNewline
                )
            }
        }
    }

    private static func appendExtractedScalar(
        _ scalar: Unicode.Scalar,
        to output: inout String,
        pendingSpace: inout Bool,
        pendingNewline: inout Bool
    ) {
        if pendingNewline {
            if !output.isEmpty && output.last != "\n" { output.append("\n") }
            pendingNewline = false
            pendingSpace = false
        } else if pendingSpace {
            if !output.isEmpty && output.last != " " && output.last != "\n" { output.append(" ") }
            pendingSpace = false
        }
        output.unicodeScalars.append(scalar)
    }

    private static func digit(_ value: UInt32, hex: Bool) -> UInt32? {
        if (48...57).contains(value) { return value - 48 }
        guard hex else { return nil }
        if (65...70).contains(value) { return value - 55 }
        if (97...102).contains(value) { return value - 87 }
        return nil
    }
}
