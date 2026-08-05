import Foundation

public enum MacClippyCategoryColorPolicy {
    public static let palette = [
        "#2563EB",
        "#7C3AED",
        "#C2410C",
        "#0F766E",
        "#A16207",
        "#4D7C0F",
    ]

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

    public static func decision(for payload: String, existingIDs: [RecordID]) -> MacClippyClipboardDropDecision {
        guard let recordID = recordID(from: payload) else { return .invalid }
        return existingIDs.contains(recordID) ? .duplicate : .accept
    }
}
