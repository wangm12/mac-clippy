import AppKit

import MacClippyCore

public enum MacClippyClipboardText {
    public static func plainText(from record: ClipboardRecord) -> String? {
        switch record {
        case let .text(value):
            value
        case let .html(value):
            attributedText(from: Data(value.utf8), documentType: .html) ??
                value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        case let .rtf(data):
            attributedText(from: data, documentType: .rtf)
        case .image, .encryptedImage, .files:
            nil
        }
    }

    private static func attributedText(
        from data: Data,
        documentType: NSAttributedString.DocumentType
    ) -> String? {
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: documentType,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        return (try? NSAttributedString(data: data, options: options, documentAttributes: nil))?.string
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
