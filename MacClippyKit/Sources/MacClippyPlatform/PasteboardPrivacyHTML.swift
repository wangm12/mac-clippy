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

    private static func updateTag(_ scalar: Unicode.Scalar, quote: inout Unicode.Scalar?, inTag: inout Bool) {
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

    private static func digit(_ value: UInt32, hex: Bool) -> UInt32? {
        if (48...57).contains(value) { return value - 48 }
        guard hex else { return nil }
        if (65...70).contains(value) { return value - 55 }
        if (97...102).contains(value) { return value - 87 }
        return nil
    }
}
