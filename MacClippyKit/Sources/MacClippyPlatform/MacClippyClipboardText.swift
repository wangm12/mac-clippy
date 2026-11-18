import AppKit

import MacClippyCore

public enum MacClippyClipboardText {
    public static func plainText(from record: ClipboardRecord) -> String? {
        switch record {
        case let .text(value):
            value
        case let .html(value):
            MacClippyPasteboardPrivacyHTML.plainText(from: value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case .rtf:
            attributedString(from: record)?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        case .image, .encryptedImage, .files:
            nil
        }
    }

    public static func attributedString(from record: ClipboardRecord) -> NSAttributedString? {
        switch record {
        case let .html(value):
            let sanitized = MacClippyPasteboardPrivacyHTML.sanitizedHTMLForAttributedPreview(value)
            return attributedString(from: Data(sanitized.utf8), documentType: .html)
        case let .rtf(data):
            return attributedString(from: data, documentType: .rtf)
        case .text, .image, .encryptedImage, .files:
            return nil
        }
    }

    private static func attributedString(
        from data: Data,
        documentType: NSAttributedString.DocumentType
    ) -> NSAttributedString? {
        if documentType == .html && !Thread.isMainThread {
            return DispatchQueue.main.sync {
                decodeAttributedString(from: data, documentType: .html)
            }
        }
        return decodeAttributedString(from: data, documentType: documentType)
    }

    private static func decodeAttributedString(
        from data: Data,
        documentType: NSAttributedString.DocumentType
    ) -> NSAttributedString? {
        autoreleasepool {
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: documentType,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
            if documentType == .html {
                options[.timeout] = 0.5
            }
            return try? NSAttributedString(data: data, options: options, documentAttributes: nil)
        }
    }
}
