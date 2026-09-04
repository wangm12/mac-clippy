import Foundation

public enum MacClippyStorageCapKind: String, Sendable, Equatable {
    case items
    case images
    case total
}

public struct MacClippyStorageCapRow: Sendable, Equatable {
    public let kind: MacClippyStorageCapKind
    public let title: String
    public let detail: String
    public let value: Int
    public let unit: String
}

/// History Settings only offers Day / Week / Month / Unlimited.
/// Item and byte caps stay enforced at these defaults and are not editable.
public enum MacClippyStorageCapPolicy {
    public static let defaultMaxItems = 10_000
    public static let defaultMaxImageMegabytes = 2_048
    public static let defaultMaxHistoryMegabytes = 4_096
    public static let exposesSettingsEditors = false

    public static func enforced(_ value: Int, default defaultValue: Int) -> Int {
        value > 0 ? value : defaultValue
    }

    public static func rows(
        maxItems _: Int = defaultMaxItems,
        maxImageMegabytes _: Int = defaultMaxImageMegabytes,
        maxHistoryMegabytes _: Int = defaultMaxHistoryMegabytes
    ) -> [MacClippyStorageCapRow] {
        []
    }

    public static func unlimitedAgeFootnote(
        maxItems _: Int = defaultMaxItems,
        maxImageMegabytes _: Int = defaultMaxImageMegabytes,
        maxHistoryMegabytes _: Int = defaultMaxHistoryMegabytes
    ) -> String? {
        nil
    }

    public static func formattedCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func formattedBytes(megabytes: Int) -> String {
        if megabytes > 0, megabytes % 1_024 == 0 {
            return "\(megabytes / 1_024) GB"
        }
        return "\(megabytes) MB"
    }
}
