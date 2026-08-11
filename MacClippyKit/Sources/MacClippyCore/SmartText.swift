import Foundation

public enum MacClippyCodeLanguage: String, Codable, Equatable, Sendable {
    case swift, javascript, python, sql, html, c, shell, unknown
}

public enum MacClippyDetectedType: Codable, Equatable, Sendable {
    case plain
    case email
    case url
    case phone
    case jwt
    case color
    case code(language: MacClippyCodeLanguage)
}

public struct MacClippyLinkCleanResult: Codable, Equatable, Sendable {
    public let cleaned: String
    public let removedCount: Int
    public let original: String

    public init(cleaned: String, removedCount: Int, original: String) {
        self.cleaned = cleaned
        self.removedCount = removedCount
        self.original = original
    }
}

public struct MacClippyDetection: Codable, Equatable, Sendable {
    public let type: MacClippyDetectedType
    public let linkClean: MacClippyLinkCleanResult?

    public init(type: MacClippyDetectedType, linkClean: MacClippyLinkCleanResult? = nil) {
        self.type = type
        self.linkClean = linkClean
    }

    public func encodedJSON() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    public static func decode(json: String) throws -> MacClippyDetection {
        try JSONDecoder().decode(Self.self, from: Data(json.utf8))
    }
}

public typealias CodeLanguage = MacClippyCodeLanguage
public typealias DetectedType = MacClippyDetectedType
public typealias LinkCleanResult = MacClippyLinkCleanResult
public typealias Detection = MacClippyDetection

public enum MacClippySmartText {
    public static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "msclkid", "mc_eid", "mc_cid",
        "igshid", "si", "ref", "ref_src", "_hsenc", "_hsmi", "vero_id", "yclid", "twclid"
    ]

    public static func detect(_ raw: String) -> DetectedType {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isColor(text) { return .color }
        if isURL(text) { return .url }
        if isEmail(text) { return .email }
        if isJWT(text) { return .jwt }
        if isPhone(text) { return .phone }
        if let language = codeLanguage(text) { return .code(language: language) }
        return .plain
    }

    public static func analyze(_ raw: String) -> Detection {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = detect(trimmed)
        return Detection(type: type, linkClean: cleanTrackingParameters(trimmed))
    }

    public static func cleanTrackingParameters(_ raw: String) -> LinkCleanResult? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: { $0.isWhitespace }),
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil,
              let queryItems = components.queryItems, !queryItems.isEmpty else { return nil }
        let kept = queryItems.filter { !isTracking($0.name) }
        let removedCount = queryItems.count - kept.count
        guard removedCount > 0 else { return nil }
        components.queryItems = kept.isEmpty ? nil : kept
        guard let cleaned = components.string else { return nil }
        return LinkCleanResult(cleaned: cleaned, removedCount: removedCount, original: value)
    }

    public static func isTracking(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.hasPrefix("utm_") || trackingParameters.contains(lowered)
    }

    public static func codeLanguage(_ text: String) -> CodeLanguage? {
        if text.hasPrefix("#!/") { return .shell }
        if text.range(of: "(?i)\\bselect\\b[\\s\\S]+\\bfrom\\b", options: .regularExpression) != nil { return .sql }
        if text.range(of: "<[A-Za-z][^>]*>[\\s\\S]*</[A-Za-z]", options: .regularExpression) != nil { return .html }
        if text.contains("func ") || text.contains("guard ") || text.contains("let ") { return .swift }
        if text.contains("=>") || text.contains("const ") || text.contains("function ") { return .javascript }
        if text.contains("def ") || text.range(of: "\\bimport\\s+\\w+:", options: .regularExpression) != nil { return .python }
        if text.contains("#include") { return .c }
        if (text.contains("{") && text.contains("}")) || text.contains(";\n") { return .unknown }
        return nil
    }

    private static func isURL(_ value: String) -> Bool {
        guard !value.contains(where: { $0.isWhitespace }), let components = URLComponents(string: value), let scheme = components.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && !(components.host?.isEmpty ?? true)
    }

    private static func isEmail(_ value: String) -> Bool {
        value.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil
    }

    private static func isPhone(_ value: String) -> Bool {
        value.range(of: "^\\+?[0-9][0-9 .()\\-]{6,}[0-9]$", options: .regularExpression) != nil
    }

    private static func isColor(_ value: String) -> Bool {
        value.range(of: "^#(?:[0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$", options: .regularExpression) != nil
            || value.range(of: "^(?:rgb|rgba|hsl)\\([^)]*\\)$", options: .regularExpression) != nil
    }

    private static func isJWT(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let data = base64URLData(String(parts[0])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["alg"] != nil || object["typ"] != nil
    }

    private static func base64URLData(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }
}

public typealias SmartTextService = MacClippySmartText

public enum MacClippyTextTransform: String, Codable, CaseIterable, Sendable {
    case uppercase
    case lowercase
    case trim
    case prettyJSON
    case cleanTrackingURL

    public func apply(to text: String) -> String {
        switch self {
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .trim: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .prettyJSON:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return text }
            return String(decoding: pretty, as: UTF8.self)
        case .cleanTrackingURL:
            return MacClippySmartText.cleanTrackingParameters(text)?.cleaned ?? text
        }
    }

    // Human-readable name shown in the card context-menu Transform submenu.
    // Kept here (Core) so the labels are stable across the dock UI and any
    // future surface, and so a pure unit test can assert every case maps to a
    // non-empty label without driving AppKit.
    public var displayName: String {
        switch self {
        case .uppercase: "Uppercase"
        case .lowercase: "Lowercase"
        case .trim: "Trim whitespace"
        case .prettyJSON: "Pretty JSON"
        case .cleanTrackingURL: "Clean tracking URL"
        }
    }
}

public typealias TextTransform = MacClippyTextTransform

public enum MacClippyTextTransforms {
    public static func apply(_ transform: TextTransform, to text: String) -> String? {
        transform.apply(to: text)
    }
}

public typealias TextTransforms = MacClippyTextTransforms

public enum MacClippyRegexBlocklistError: Error {
    case invalidPattern(String)
}

public struct MacClippyRegexBlocklist: Sendable {
    private let expressions: [String]

    public init(patterns: [String] = []) throws {
        for pattern in patterns {
            guard (try? NSRegularExpression(pattern: pattern)) != nil else { throw MacClippyRegexBlocklistError.invalidPattern(pattern) }
        }
        expressions = patterns
    }

    public func matches(_ text: String) -> Bool {
        expressions.contains { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
            return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    public static func isValid(pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }

    public static func validate(_ pattern: String) throws {
        guard isValid(pattern: pattern) else { throw MacClippyRegexBlocklistError.invalidPattern(pattern) }
    }

    public func isBlocked(_ text: String) -> Bool { matches(text) }
    public func patternsList() -> [String] { expressions }
}

public typealias RegexBlocklist = MacClippyRegexBlocklist

public struct MacClippyCaptureExclusionRules: Sendable, Equatable {
    public var concealedPasteboardTypes: Set<String>
    public var transientPasteboardTypes: Set<String>
    public var autoGeneratedPasteboardTypes: Set<String>
    public var excludedAppBundleIDs: Set<String>
    public var excludedTextPatterns: [String]
    public var captureAll: Bool

    public static let defaultConcealedPasteboardTypes = Set(["org.nspasteboard.ConcealedType"])
    public static let defaultTransientPasteboardTypes = Set(["org.nspasteboard.TransientType"])
    public static let defaultAutoGeneratedPasteboardTypes = Set(["org.nspasteboard.AutoGeneratedType"])
    public static let defaultExcludedAppBundleIDs = Set([
        "com.agilebits.onepassword7",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.dashlane.Dashlane",
        "com.lastpass.LastPass",
        "org.keepassxc.keepassxc",
        "com.apple.keychainaccess"
    ])

    // P0 no-filter capture: the default rules retain every external
    // representation, including concealed, transient, custom, and unknown
    // UTIs. Internal Mac Clippy writes are suppressed by the pasteboard write
    // sentinel in MacClippyPlatform, not by these rules. Callers that still
    // want the legacy concealed/transient/app filtering can construct the
    // rules explicitly via legacyDefault().
    public init(
        concealedPasteboardTypes: Set<String> = MacClippyCaptureExclusionRules.defaultConcealedPasteboardTypes,
        transientPasteboardTypes: Set<String> = MacClippyCaptureExclusionRules.defaultTransientPasteboardTypes,
        autoGeneratedPasteboardTypes: Set<String> = MacClippyCaptureExclusionRules.defaultAutoGeneratedPasteboardTypes,
        excludedAppBundleIDs: Set<String> = MacClippyCaptureExclusionRules.defaultExcludedAppBundleIDs,
        excludedTextPatterns: [String] = [],
        captureAll: Bool = false
    ) {
        self.concealedPasteboardTypes = concealedPasteboardTypes
        self.transientPasteboardTypes = transientPasteboardTypes
        self.autoGeneratedPasteboardTypes = autoGeneratedPasteboardTypes
        self.excludedAppBundleIDs = Set(excludedAppBundleIDs.map { $0.lowercased() })
        self.excludedTextPatterns = excludedTextPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.captureAll = captureAll
    }

    // The pre-P0 default rules, preserved for callers that explicitly want to
    // restore concealed/transient/app-bundle filtering. The runtime no longer
    // uses this; it is here for backward compatibility and future opt-in UI.
    public static func legacyDefault(
        concealedPasteboardTypes: Set<String> = defaultConcealedPasteboardTypes,
        transientPasteboardTypes: Set<String> = defaultTransientPasteboardTypes,
        excludedAppBundleIDs: Set<String> = []
    ) -> MacClippyCaptureExclusionRules {
        MacClippyCaptureExclusionRules(
            concealedPasteboardTypes: concealedPasteboardTypes,
            transientPasteboardTypes: transientPasteboardTypes,
            autoGeneratedPasteboardTypes: defaultAutoGeneratedPasteboardTypes,
            excludedAppBundleIDs: defaultExcludedAppBundleIDs.union(excludedAppBundleIDs)
        )
    }

    public func shouldExclude(appBundleID: String?, pasteboardTypes: [String]) -> Bool {
        if let appBundleID, excludedAppBundleIDs.contains(appBundleID.lowercased()) { return true }
        guard !captureAll else { return false }
        return pasteboardTypes.contains {
            concealedPasteboardTypes.contains($0)
                || transientPasteboardTypes.contains($0)
                || autoGeneratedPasteboardTypes.contains($0)
        }
    }

    public func isExcluded(appBundleID: String?, pasteboardTypes: [String]) -> Bool {
        shouldExclude(appBundleID: appBundleID, pasteboardTypes: pasteboardTypes)
    }

    public func shouldExcludeText(_ text: String) -> Bool {
        excludedTextPatterns.contains { pattern in
            // A persisted pattern can outlive the validation path that wrote
            // it (for example after a settings migration). Fail closed so a
            // malformed privacy rule never silently permits capture.
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return true }
            return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }
}

public typealias CaptureExclusionRules = MacClippyCaptureExclusionRules
