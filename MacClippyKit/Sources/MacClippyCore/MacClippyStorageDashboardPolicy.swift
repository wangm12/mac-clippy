import Foundation

public struct MacClippyStorageUsage: Equatable, Sendable {
    public var itemCount: Int
    public var imageBytes: Int64
    public var totalBytes: Int64
    public var maxItems: Int
    public var maxImageBytes: Int64
    public var maxTotalBytes: Int64

    public init(
        itemCount: Int,
        imageBytes: Int64,
        totalBytes: Int64,
        maxItems: Int,
        maxImageBytes: Int64,
        maxTotalBytes: Int64
    ) {
        self.itemCount = itemCount
        self.imageBytes = imageBytes
        self.totalBytes = totalBytes
        self.maxItems = maxItems
        self.maxImageBytes = maxImageBytes
        self.maxTotalBytes = maxTotalBytes
    }
}

public struct MacClippyImageCompressReport: Equatable, Sendable {
    public var compressedCount: Int
    public var bytesSaved: Int64

    public init(compressedCount: Int = 0, bytesSaved: Int64 = 0) {
        self.compressedCount = compressedCount
        self.bytesSaved = bytesSaved
    }
}

public struct MacClippyStorageDashboardRow: Equatable, Sendable {
    public var kind: MacClippyStorageCapKind
    public var title: String
    public var usedLabel: String
    public var capLabel: String
    public var fraction: Double

    public init(
        kind: MacClippyStorageCapKind,
        title: String,
        usedLabel: String,
        capLabel: String,
        fraction: Double
    ) {
        self.kind = kind
        self.title = title
        self.usedLabel = usedLabel
        self.capLabel = capLabel
        self.fraction = fraction
    }
}

/// Settings dashboard over existing retention caps, plus eligibility for
/// one-click compression of old unpinned images. Does not rewrite storage.
public enum MacClippyStorageDashboardPolicy {
    public static let compressMinimumAge: TimeInterval = 7 * 24 * 60 * 60
    public static let compressMinimumBytes = 256 * 1_024
    public static let compressTargetMaxPixelSize = 2_048
    public static let compressMinimumSavingsFraction = 0.10

    public static func rows(from usage: MacClippyStorageUsage) -> [MacClippyStorageDashboardRow] {
        [
            MacClippyStorageDashboardRow(
                kind: .items,
                title: "Items in library",
                usedLabel: MacClippyStorageCapPolicy.formattedCount(usage.itemCount),
                capLabel: "\(MacClippyStorageCapPolicy.formattedCount(usage.maxItems)) items",
                fraction: fraction(used: Int64(usage.itemCount), cap: Int64(usage.maxItems))
            ),
            MacClippyStorageDashboardRow(
                kind: .images,
                title: "Images",
                usedLabel: formattedByteCount(usage.imageBytes),
                capLabel: formattedByteCount(usage.maxImageBytes),
                fraction: fraction(used: usage.imageBytes, cap: usage.maxImageBytes)
            ),
            MacClippyStorageDashboardRow(
                kind: .total,
                title: "On disk",
                usedLabel: formattedByteCount(usage.totalBytes),
                capLabel: formattedByteCount(usage.maxTotalBytes),
                fraction: fraction(used: usage.totalBytes, cap: usage.maxTotalBytes)
            )
        ]
    }

    public static func shouldCompress(
        isProtected: Bool,
        modified: Date,
        now: Date,
        byteCount: Int,
        longestEdge: Int
    ) -> Bool {
        !isProtected
            && now.timeIntervalSince(modified) >= compressMinimumAge
            && byteCount >= compressMinimumBytes
            && longestEdge > compressTargetMaxPixelSize
    }

    public static func isWorthReplacing(originalBytes: Int, compressedBytes: Int) -> Bool {
        guard compressedBytes > 0, compressedBytes < originalBytes else { return false }
        let saved = originalBytes - compressedBytes
        return Double(saved) >= Double(originalBytes) * compressMinimumSavingsFraction
    }

    public static func compressMessage(compressedCount: Int, bytesSaved: Int64) -> String {
        guard compressedCount > 0, bytesSaved > 0 else {
            return "No old images needed compression."
        }
        return "Compressed \(compressedCount) old image(s) and freed \(formattedByteCount(bytesSaved))."
    }

    public static func formattedByteCount(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 MB" }
        let megabytes = max(1, (bytes + 512 * 1_024) / (1_024 * 1_024))
        return MacClippyStorageCapPolicy.formattedBytes(megabytes: Int(megabytes))
    }

    public static func directoryByteCount(at url: URL, fileManager: FileManager = .default) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    private static func fraction(used: Int64, cap: Int64) -> Double {
        guard cap > 0 else { return 0 }
        return Double(used) / Double(cap)
    }
}
