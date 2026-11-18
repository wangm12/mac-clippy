import Foundation

enum MacClippyPasteboardPrivacyRTF {
    private static let excludedDestinations: Set<String> = [
        "fonttbl", "colortbl", "stylesheet", "info", "pict", "object", "objdata", "fldinst", "listtable",
        "listoverridetable", "header", "footer", "annotation", "datastore", "themedata"
    ]
    private static let controlText: [String: String] = [
        "par": "\n", "line": "\n", "tab": "\t", "emdash": "—", "endash": "–", "bullet": "•",
        "lquote": "‘", "rquote": "’", "ldblquote": "“", "rdblquote": "”", "enspace": "\u{2002}",
        "emspace": "\u{2003}", "page": "\n", "sect": "\n", "cell": "\t", "row": "\n",
        "nestcell": "\t", "nestrow": "\n"
    ]
    private static let formattingControls: Set<String> = [
        "deff", "adeff", "deflang", "deflangfe", "f", "af", "fnil", "froman", "fswiss", "fmodern",
        "fscript", "fdecor", "ftech", "fbidi", "fs", "afs", "b", "ab", "i", "ai", "ul", "ulnone",
        "uld", "uldb", "ulw", "super", "sub", "nosupersub", "strike", "striked", "outl", "shad",
        "cf", "cb", "cbpat", "highlight", "red", "green", "blue", "pard", "plain", "ql", "qr",
        "qc", "qj", "fi", "li", "ri", "sb", "sa", "sl", "slmult", "tx", "expnd", "expndtw",
        "kerning", "lang", "langfe", "ltrpar", "rtlpar", "ltrch", "rtlch", "paperw", "paperh",
        "margl", "margr", "margt", "margb", "vieww", "viewh", "viewkind", "deftab", "field",
        "fldrslt", "cocoartf", "cocoatextscaling", "cocoaplatform", "strokewidth", "stroke"
    ]
    static func texts(
        _ data: Data, isWithinBudget: @escaping @Sendable () -> Bool
    ) -> (source: String, rendered: String)? {
        guard data.starts(with: Data("{\\rtf1".utf8)) else { return nil }
        var parser = Parser(bytes: Array(data), isWithinBudget: isWithinBudget)
        return parser.parse()
    }

    private struct Group {
        var unicodeFallbackCount = 1
        var encoding = String.Encoding.windowsCP1252
        var excludesRenderedText = false
    }

    private struct Parser {
        let bytes: [UInt8]
        let isWithinBudget: @Sendable () -> Bool
        var index = 0
        var group = Group()
        var groups: [Group] = []
        var fallbackRemaining = 0
        var byteText: [UInt8] = []
        var source: [UInt16] = []
        var rendered: [UInt16] = []
        var iterations = 0

        mutating func parse() -> (source: String, rendered: String)? {
            while index < bytes.count {
                if iterations % 256 == 0 && !isWithinBudget() { return nil }
                iterations += 1
                let byte = bytes[index]
                index += 1
                guard readByte(byte) else { return nil }
            }
            guard groups.isEmpty, fallbackRemaining == 0, flushBytes(), isWithinBudget(),
                  validUTF16(source), validUTF16(rendered) else { return nil }
            return (String(decoding: source, as: UTF16.self), String(decoding: rendered, as: UTF16.self))
        }

        private mutating func readByte(_ byte: UInt8) -> Bool {
            switch byte {
            case 123:
                guard fallbackRemaining == 0, flushBytes(), groups.count < 128 else { return false }
                groups.append(group)
            case 125:
                guard fallbackRemaining == 0, flushBytes(), let previous = groups.popLast() else { return false }
                group = previous
            case 92: return readControl()
            case 10, 13: return true
            default: appendByte(byte)
            }
            return true
        }

        private mutating func appendByte(_ byte: UInt8) {
            if fallbackRemaining > 0 {
                fallbackRemaining -= 1
            } else {
                byteText.append(byte)
            }
        }

        private mutating func readControl() -> Bool {
            guard index < bytes.count else { return false }
            let byte = bytes[index]
            index += 1
            if byte == 39 { return readHexByte() }
            if byte == 92 || byte == 123 || byte == 125 {
                appendByte(byte)
                return true
            }
            guard fallbackRemaining == 0, flushBytes() else { return false }
            guard isLetter(byte) else { return readSymbol(byte) }
            let start = index - 1
            while index < bytes.count && isLetter(bytes[index]) {
                guard index - start < 64 else { return false }
                index += 1
            }
            guard let word = String(bytes: bytes[start..<index], encoding: .utf8),
                  let argument = readArgument() else { return false }
            if index < bytes.count && bytes[index] == 32 { index += 1 }
            return apply(word, argument: argument.value)
        }

        private mutating func readHexByte() -> Bool {
            guard index + 1 < bytes.count,
                  let first = hex(bytes[index]), let second = hex(bytes[index + 1]) else { return false }
            index += 2
            appendByte(first * 16 + second)
            return true
        }

        private mutating func readArgument() -> (value: Int?, valid: Bool)? {
            var sign = 1
            if index < bytes.count && bytes[index] == 45 { sign = -1; index += 1 }
            var value = 0
            var digits = 0
            while index < bytes.count && (48...57).contains(bytes[index]) {
                guard digits < 9 else { return nil }
                value = value * 10 + Int(bytes[index] - 48)
                index += 1
                digits += 1
            }
            guard digits > 0 || sign == 1 else { return nil }
            return (digits == 0 ? nil : sign * value, true)
        }

        private mutating func apply(_ word: String, argument: Int?) -> Bool {
            if MacClippyPasteboardPrivacyRTF.excludedDestinations.contains(word) {
                group.excludesRenderedText = true
                return true
            }
            if let text = MacClippyPasteboardPrivacyRTF.controlText[word] {
                append(Array(text.utf16))
                return true
            }
            if let result = applyEncoding(word, argument: argument) { return result }
            switch word {
            case "u":
                guard let argument, (-32768...32767).contains(argument) else { return false }
                append([UInt16(bitPattern: Int16(argument))])
                fallbackRemaining = group.unicodeFallbackCount
            case "uc":
                guard let argument, (0...16).contains(argument) else { return false }
                group.unicodeFallbackCount = argument
            case "bin":
                guard let argument, argument >= 0, argument <= bytes.count - index else { return false }
                index += argument
            default: return MacClippyPasteboardPrivacyRTF.formattingControls.contains(word)
            }
            return true
        }

        private mutating func applyEncoding(_ word: String, argument: Int?) -> Bool? {
            switch word {
            case "rtf": return argument == 1
            case "ansicpg":
                guard let argument, let encoding = encoding(argument) else { return false }
                group.encoding = encoding
            case "ansi": group.encoding = .windowsCP1252
            case "mac": group.encoding = .macOSRoman
            case "pc", "pca": return false
            case "fcharset": return argument == 0 || argument == 1
            default: return nil
            }
            return true
        }

        private mutating func readSymbol(_ byte: UInt8) -> Bool {
            switch byte {
            case 42: group.excludesRenderedText = true
            case 126: append([0xA0])
            case 45: append([0xAD])
            case 95: append([0x2011])
            case 10, 13: append([10])
            default: return false
            }
            return true
        }

        private mutating func flushBytes() -> Bool {
            guard !byteText.isEmpty else { return true }
            guard let text = String(bytes: byteText, encoding: group.encoding) else { return false }
            append(Array(text.utf16))
            byteText.removeAll(keepingCapacity: true)
            return isWithinBudget()
        }

        private mutating func append(_ units: [UInt16]) {
            source.append(contentsOf: units)
            if !group.excludesRenderedText { rendered.append(contentsOf: units) }
        }

        private func encoding(_ codepage: Int) -> String.Encoding? {
            switch codepage {
            case 1252: .windowsCP1252
            case 65001: .utf8
            case 10000: .macOSRoman
            case 20127: .ascii
            case 28591: .isoLatin1
            default: nil
            }
        }

        private func validUTF16(_ units: [UInt16]) -> Bool {
            var needsLowSurrogate = false
            for unit in units {
                if needsLowSurrogate {
                    guard (0xDC00...0xDFFF).contains(unit) else { return false }
                    needsLowSurrogate = false
                } else if (0xD800...0xDBFF).contains(unit) {
                    needsLowSurrogate = true
                } else if (0xDC00...0xDFFF).contains(unit) { return false }
            }
            return !needsLowSurrogate
        }

        private func isLetter(_ byte: UInt8) -> Bool { (65...90).contains(byte) || (97...122).contains(byte) }
        private func hex(_ byte: UInt8) -> UInt8? {
            if (48...57).contains(byte) { return byte - 48 }
            if (65...70).contains(byte) { return byte - 55 }
            if (97...102).contains(byte) { return byte - 87 }
            return nil
        }
    }
}
