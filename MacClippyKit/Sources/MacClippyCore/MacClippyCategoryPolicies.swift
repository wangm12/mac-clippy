import Foundation

public enum MacClippyCategoryColorPolicy {
    // Stable values inspired by the macOS Theme accent choices. Categories
    // are persisted as HEX for backwards compatibility, so these are
    // intentionally stable rather than appearance-dependent NSColor values.
    public static let palette = [
        "#0A84FF", // blue
        "#BF5AF2", // purple
        "#FF375F", // pink
        "#FF453A", // red
        "#FF9F0A", // orange
        "#FFD60A", // yellow
        "#30D158", // green
        "#8E8E93" // graphite
    ]

    public static func name(for color: String) -> String {
        switch palette.firstIndex(of: color) {
        case 0: "blue"
        case 1: "purple"
        case 2: "pink"
        case 3: "red"
        case 4: "orange"
        case 5: "yellow"
        case 6: "green"
        case 7: "graphite"
        default: "custom color"
        }
    }

    public static func displayName(for color: String) -> String {
        let raw = name(for: color)
        return raw == "custom color" ? "Custom" : raw.capitalized
    }

    public static func color(for pinboard: Pinboard) -> String {
        color(for: pinboard.id, name: pinboard.name, preferred: pinboard.color)
    }

    public static func color(for id: RecordID, name: String, preferred: String? = nil) -> String {
        if let preferred = preferred?.trimmingCharacters(in: .whitespacesAndNewlines), !preferred.isEmpty {
            return preferred
        }

        let seed = "\(id.rawValue)|\(name)"
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

public enum MacClippyClipboardDropDecision: Equatable, Sendable {
    case invalid
    case accept
    case duplicate
}

public enum MacClippyClipboardDropPolicy {
    public static func recordID(from payload: String) -> RecordID? {
        RecordID(rawValue: payload.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func preferredTypeIdentifier(among typeIdentifiers: [String]) -> String? {
        typeIdentifiers.contains(MacClippyCardDragPolicy.recordTypeIdentifier)
            ? MacClippyCardDragPolicy.recordTypeIdentifier
            : nil
    }

    public static func decision(for payload: String, existingIDs: [RecordID]) -> MacClippyClipboardDropDecision {
        guard let recordID = recordID(from: payload) else { return .invalid }
        return existingIDs.contains(recordID) ? .duplicate : .accept
    }
}
