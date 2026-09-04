import Foundation

/// Tokens for `app:` filters. These stay off the FTS document so a bare
/// `Safari` or `chat` query matches clipboard text, not every clip from
/// that app.
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

    public static func preferredDisplayName(stored: String?, resolved: String?) -> String? {
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, trimmed.caseInsensitiveCompare(unknownDisplayName) != .orderedSame {
            return trimmed
        }
        let resolvedTrimmed = resolved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return resolvedTrimmed.isEmpty ? nil : resolvedTrimmed
    }
}
