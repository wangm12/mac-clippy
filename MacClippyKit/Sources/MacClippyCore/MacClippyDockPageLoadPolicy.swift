import Foundation

/// Visible dock pages stay on `clipboard_records` metadata. Decrypting
/// `clipboard_representations` is reserved for copy/paste, details, and export.
public enum MacClippyDockPageLoadPolicy {
    public static func canProjectFromMetadata(contentKind: MacClippyContentKind?) -> Bool {
        contentKind != nil
    }

    /// Card image size from the persisted preview (`(image 12x34)`), so a
    /// visible page does not need to open the encrypted envelope.
    public static func imagePixelSize(fromPreview preview: String) -> (width: Int, height: Int)? {
        guard preview.hasPrefix("(image "), preview.hasSuffix(")") else { return nil }
        let inner = preview.dropFirst(7).dropLast()
        let parts = inner.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]),
              width > 0,
              height > 0 else {
            return nil
        }
        return (width, height)
    }

    public static func fileURLs(fromPreview preview: String) -> [URL] {
        MacClippyFilePresentation.fileURLs(fromStoredPreview: preview)
    }
}
