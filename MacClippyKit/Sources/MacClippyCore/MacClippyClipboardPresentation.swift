import Foundation

public struct MacClippyRGB: Equatable, Sendable {
    public let red: Int
    public let green: Int
    public let blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct MacClippyColorSwatch: Equatable, Sendable {
    public let hex: String
    public let rgb: MacClippyRGB
    public let hslDisplay: String

    public init(hex: String, rgb: MacClippyRGB, hslDisplay: String) {
        self.hex = hex
        self.rgb = rgb
        self.hslDisplay = hslDisplay
    }
}

public enum MacClippyClipboardPresentationKind: Equatable, Sendable {
    case plain
    case url
    case color(MacClippyColorSwatch)
    case json
    case code
}

public enum MacClippyClipboardPresentation {
    public static func kind(forPlainText text: String) -> MacClippyClipboardPresentationKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if case .color = MacClippySmartText.detect(trimmed),
           let swatch = MacClippySmartText.colorSwatch(from: trimmed) {
            return .color(swatch)
        }
        if url(fromPlainText: trimmed) != nil { return .url }
        if isJSONObjectOrArray(trimmed) { return .json }
        if isCode(trimmed) { return .code }
        return .plain
    }

    public static func url(fromPlainText text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("://") || trimmed.hasPrefix("www.") else { return nil }
        guard !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

        let candidate = trimmed.hasPrefix("www.") ? "https://\(trimmed)" : trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    public static func isCode(_ preview: String) -> Bool {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)

        let buildOutputMarkers = [
            "-Xlinker",
            "-install_name",
            "LinkFileList",
            ".swiftmodule",
            ".dylib"
        ]
        let markerCount = buildOutputMarkers.reduce(into: 0) { count, marker in
            if trimmed.contains(marker) { count += 1 }
        }
        if markerCount >= 2 { return false }

        if trimmed.hasPrefix("#!") { return true }

        let openBraces = trimmed.filter { $0 == "{" }.count
        let semicolons = trimmed.filter { $0 == ";" }.count
        if openBraces >= 2 || semicolons >= 2 { return true }

        let keywords = [
            "func ", "def ", "class ", "import ", "const ", "let ", "var ",
            "public ", "private ", "return ", "if ", "for ", "while "
        ]
        if lines.contains(where: { line in
            keywords.contains { line.trimmingCharacters(in: .whitespaces).hasPrefix($0) }
        }) {
            return true
        }
        return false
    }

    private static func isJSONObjectOrArray(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return object is [Any] || object is [String: Any]
    }
}

extension MacClippySmartText {
    public static func colorSwatch(from raw: String) -> MacClippyColorSwatch? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isColor(value), let rgb = parseColorRGB(value) else { return nil }
        return MacClippyColorSwatch(
            hex: canonicalHex(for: rgb),
            rgb: rgb,
            hslDisplay: hslDisplay(for: rgb)
        )
    }

    private static func parseColorRGB(_ value: String) -> MacClippyRGB? {
        if value.hasPrefix("#") {
            return parseHexRGB(value)
        }
        let lowercased = value.lowercased()
        if lowercased.hasPrefix("rgb(") || lowercased.hasPrefix("rgba(") {
            return parseRGBFunction(value)
        }
        return nil
    }

    private static func parseHexRGB(_ value: String) -> MacClippyRGB? {
        let hex = String(value.dropFirst())
        let expanded: String
        switch hex.count {
        case 3, 4:
            expanded = hex.prefix(3).flatMap { [$0, $0] }.map(String.init).joined()
        case 6, 8:
            expanded = String(hex.prefix(6))
        default:
            return nil
        }

        guard let red = Int(expanded.prefix(2), radix: 16),
              let green = Int(expanded.dropFirst(2).prefix(2), radix: 16),
              let blue = Int(expanded.dropFirst(4).prefix(2), radix: 16) else {
            return nil
        }
        return MacClippyRGB(red: red, green: green, blue: blue)
    }

    private static func parseRGBFunction(_ value: String) -> MacClippyRGB? {
        guard let open = value.firstIndex(of: "("),
              let close = value.lastIndex(of: ")"),
              open < close else {
            return nil
        }
        let components = value[value.index(after: open)..<close]
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard components.count == 3 || components.count == 4,
              let red = parseByte(components[0]),
              let green = parseByte(components[1]),
              let blue = parseByte(components[2]) else {
            return nil
        }
        return MacClippyRGB(red: red, green: green, blue: blue)
    }

    private static func parseByte(_ value: String) -> Int? {
        guard let byte = Int(value), (0...255).contains(byte) else { return nil }
        return byte
    }

    private static func canonicalHex(for rgb: MacClippyRGB) -> String {
        String(format: "#%02X%02X%02X", rgb.red, rgb.green, rgb.blue)
    }

    private static func hslDisplay(for rgb: MacClippyRGB) -> String {
        let red = Double(rgb.red) / 255
        let green = Double(rgb.green) / 255
        let blue = Double(rgb.blue) / 255
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2

        let hue: Double
        let saturation: Double
        if delta == 0 {
            hue = 0
            saturation = 0
        } else {
            saturation = delta / (1 - abs(2 * lightness - 1))
            if maximum == red {
                hue = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                hue = 60 * (((blue - red) / delta) + 2)
            } else {
                hue = 60 * (((red - green) / delta) + 4)
            }
        }

        let normalizedHue = hue < 0 ? hue + 360 : hue
        let roundedSaturation = Int((saturation * 100).rounded())
        let roundedLightness = Int((lightness * 100).rounded())
        return "hsl(\(Int(normalizedHue.rounded())), \(roundedSaturation)%, \(roundedLightness)%)"
    }
}
