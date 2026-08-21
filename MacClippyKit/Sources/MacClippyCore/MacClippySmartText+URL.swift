import Foundation

extension MacClippySmartText {
    public static func matchesURL(_ raw: String) -> Bool {
        MacClippyClipboardPresentation.url(fromPlainText: raw) != nil
    }
}
