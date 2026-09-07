import Foundation

public enum MacClippyThumbnailCachePolicy {
    public static let defaultMaxPixelSize = 480
    public static let directoryName = "thumbnails"

    public static func shouldDecode(isCardVisible: Bool) -> Bool {
        isCardVisible
    }

    /// A remounted `.task` for the same file or record must keep the last
    /// pixels. Clearing on every restart is what makes file cards flash.
    public static func shouldClearDisplayedImage(
        displayedIdentity: String?,
        loadingIdentity: String
    ) -> Bool {
        displayedIdentity != loadingIdentity
    }

    public static func fileName(recordID: String, maxPixelSize: Int) -> String {
        "\(recordID)#\(max(1, maxPixelSize)).thumb"
    }
}
