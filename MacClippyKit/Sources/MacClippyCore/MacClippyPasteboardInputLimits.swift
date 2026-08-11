import Foundation

/// Hard bounds for untrusted pasteboard input. NSPasteboard's Data API
/// materializes before returning, so these limits cannot prevent the system
/// provider's allocation; they do prevent retaining, encrypting, indexing,
/// and concurrently persisting unbounded payloads after materialization.
public struct MacClippyPasteboardInputLimits: Sendable, Equatable {
    public static let truncatedUTIMarker = "com.macallyouneed.macclippy.truncated-uti"

    public let maxItemsPerChange: Int
    public let maxRepresentationsPerItem: Int
    public let maxUTIBytes: Int
    public let maxRepresentationsPerRecord: Int
    public let maxRepresentationBytes: Int
    public let maxChangeBytes: Int
    public let maxRecordBytes: Int
    public let maxHistoryBytes: Int

    public init(
        maxItemsPerChange: Int = 32,
        maxRepresentationsPerItem: Int = 64,
        maxUTIBytes: Int = 256,
        maxRepresentationsPerRecord: Int = 256,
        maxRepresentationBytes: Int = 128 * 1_024 * 1_024,
        maxChangeBytes: Int = 256 * 1_024 * 1_024,
        maxRecordBytes: Int = 128 * 1_024 * 1_024,
        maxHistoryBytes: Int = 4 * 1_024 * 1_024 * 1_024
    ) {
        self.maxItemsPerChange = max(1, maxItemsPerChange)
        self.maxRepresentationsPerItem = max(1, maxRepresentationsPerItem)
        self.maxUTIBytes = max(1, maxUTIBytes)
        self.maxRepresentationsPerRecord = max(1, maxRepresentationsPerRecord)
        self.maxRepresentationBytes = max(1, maxRepresentationBytes)
        self.maxChangeBytes = max(self.maxRepresentationBytes, maxChangeBytes)
        self.maxRecordBytes = max(1, maxRecordBytes)
        self.maxHistoryBytes = max(self.maxRecordBytes, maxHistoryBytes)
    }

    public static let `default` = MacClippyPasteboardInputLimits()
}
