import Foundation

/// Search tokens for the app a clip was copied from. Bundle IDs stay
/// searchable; the last dotted component and a localized display name cover
/// queries like `Safari` and `微信` without a new storage column.
public enum MacClippySourceAppSearch {
    public static let unknownDisplayName = "Unknown source"

    public static func segments(bundleID: String?, displayName: String?) -> [String] {
        var segments: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }
            guard trimmed.caseInsensitiveCompare(unknownDisplayName) != .orderedSame else {
                return
            }
            guard seen.insert(trimmed.lowercased()).inserted else { return }
            segments.append(trimmed)
        }

        append(bundleID)
        if let bundleID {
            let last = bundleID.split(separator: ".").last.map(String.init)
            append(last)
        }
        append(displayName)
        return segments
    }
}
