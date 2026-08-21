import AppKit

import MacClippyCore

public enum MacClippyClipboardText {
    public static func plainText(from record: ClipboardRecord) -> String? {
        switch record {
        case let .text(value):
            value
        case let .html(value):
            attributedString(from: record)?.string.trimmingCharacters(in: .whitespacesAndNewlines) ??
                value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
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
            attributedString(from: Data(value.utf8), documentType: .html)
        case let .rtf(data):
            attributedString(from: data, documentType: .rtf)
        case .text, .image, .encryptedImage, .files:
            nil
        }
    }

    private static func attributedString(
        from data: Data,
        documentType: NSAttributedString.DocumentType
    ) -> NSAttributedString? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: documentType,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        return try? NSAttributedString(data: data, options: options, documentAttributes: nil)
    }
}
