import Foundation

public enum MacClippyThumbnailCachePolicy {
    public static let defaultMaxPixelSize = 480
    public static let directoryName = "thumbnails"

    public static func shouldDecode(isCardVisible: Bool) -> Bool {
        isCardVisible
    }

    public static func fileName(recordID: String, maxPixelSize: Int) -> String {
        "\(recordID)#\(max(1, maxPixelSize)).thumb"
    }
}
