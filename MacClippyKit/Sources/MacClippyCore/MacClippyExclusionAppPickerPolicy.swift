import Foundation

public struct MacClippyExcludedAppRow: Equatable, Sendable, Identifiable {
    public var id: String { bundleID }
    public let bundleID: String
    public let title: String
    public let isBuiltIn: Bool

    public var canRemove: Bool { !isBuiltIn }

    public init(bundleID: String, title: String, isBuiltIn: Bool) {
        self.bundleID = bundleID
        self.title = title
        self.isBuiltIn = isBuiltIn
    }
}

/// Settings stores extra excluded apps as a comma-separated bundle-ID list.
/// The picker adds and removes those IDs from chosen .app bundles; built-in
/// password managers stay excluded without being persisted.
public enum MacClippyExclusionAppPickerPolicy {
    public static let builtInBundleIDs = CaptureExclusionRules.defaultExcludedAppBundleIDs

    public static func normalizedBundleID(_ raw: String) -> String? {
        let identifier = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return identifier.isEmpty ? nil : identifier
    }

    public static func parseStoredList(_ raw: String) -> [String] {
        var seen = Set<String>()
        var identifiers: [String] = []
        for part in raw.split(separator: ",") {
            guard let identifier = normalizedBundleID(String(part)), !seen.contains(identifier) else {
                continue
            }
            seen.insert(identifier)
            identifiers.append(identifier)
        }
        return identifiers
    }

    public static func encodeStoredList(_ identifiers: [String]) -> String {
        var seen = Set<String>()
        var unique: [String] = []
        for raw in identifiers {
            guard let identifier = normalizedBundleID(raw),
                  !builtInBundleIDs.contains(identifier),
                  !seen.contains(identifier) else {
                continue
            }
            seen.insert(identifier)
            unique.append(identifier)
        }
        return unique.joined(separator: ",")
    }

    public static func userBundleIDs(
        from stored: String,
        builtIn: Set<String> = builtInBundleIDs
    ) -> [String] {
        parseStoredList(stored).filter { !builtIn.contains($0) }
    }

    public static func add(_ bundleID: String, to stored: String) -> String {
        guard let identifier = normalizedBundleID(bundleID),
              !builtInBundleIDs.contains(identifier) else {
            return encodeStoredList(userBundleIDs(from: stored))
        }
        return encodeStoredList(userBundleIDs(from: stored) + [identifier])
    }

    public static func remove(_ bundleID: String, from stored: String) -> String {
        guard let identifier = normalizedBundleID(bundleID),
              !builtInBundleIDs.contains(identifier) else {
            return encodeStoredList(userBundleIDs(from: stored))
        }
        return encodeStoredList(userBundleIDs(from: stored).filter { $0 != identifier })
    }

    public static func displayTitle(bundleID: String, localizedName: String?) -> String {
        if let localizedName {
            let trimmed = localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return bundleID
    }

    public static func rows(
        stored: String,
        displayNames: [String: String] = [:]
    ) -> [MacClippyExcludedAppRow] {
        let userRows = userBundleIDs(from: stored).map { identifier in
            MacClippyExcludedAppRow(
                bundleID: identifier,
                title: displayTitle(bundleID: identifier, localizedName: displayNames[identifier]),
                isBuiltIn: false
            )
        }
        let builtInRows = builtInBundleIDs.sorted().map { identifier in
            MacClippyExcludedAppRow(
                bundleID: identifier,
                title: displayTitle(bundleID: identifier, localizedName: displayNames[identifier]),
                isBuiltIn: true
            )
        }
        return userRows + builtInRows
    }
}
