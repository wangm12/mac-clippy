import Foundation

import MacClippyCore

public struct MacClippyCardDragPayload: Equatable, Sendable {
    public let typeIdentifier: String
    public let data: Data

    public init(typeIdentifier: String, data: Data) {
        self.typeIdentifier = typeIdentifier
        self.data = data
    }
}

/// Turns a stored pasteboard payload into the bytes a drag representation
/// should promise. The private record-id type carries only the id; public
/// types carry the actual clipboard body so other apps can accept the drop.
public enum MacClippyCardDragExportPolicy {
    public static func payload(
        for representation: MacClippyCardDragRepresentation,
        recordID: RecordID,
        content: MacClippyPasteboardContent
    ) -> MacClippyCardDragPayload? {
        switch representation {
        case .recordID:
            return MacClippyCardDragPayload(
                typeIdentifier: MacClippyCardDragPolicy.recordTypeIdentifier,
                data: Data(recordID.rawValue.utf8)
            )
        case .plainText:
            guard let text = plainText(from: content) else { return nil }
            return MacClippyCardDragPayload(
                typeIdentifier: MacClippyCardDragPolicy.typeIdentifier(for: .plainText),
                data: Data(text.utf8)
            )
        case .rtf:
            guard case let .rtf(data, _) = content else { return nil }
            return MacClippyCardDragPayload(
                typeIdentifier: MacClippyCardDragPolicy.typeIdentifier(for: .rtf),
                data: data
            )
        case .html:
            guard case let .html(value, _) = content else { return nil }
            return MacClippyCardDragPayload(
                typeIdentifier: MacClippyCardDragPolicy.typeIdentifier(for: .html),
                data: Data(value.utf8)
            )
        case .image:
            guard case let .image(data) = content else { return nil }
            let image = imageRepresentation(for: data)
            return MacClippyCardDragPayload(typeIdentifier: image.typeIdentifier, data: image.data)
        case .fileURL:
            guard case let .files(urls) = content, let url = urls.first else { return nil }
            return MacClippyCardDragPayload(
                typeIdentifier: MacClippyCardDragPolicy.typeIdentifier(for: .fileURL),
                data: Data(url.absoluteString.utf8)
            )
        }
    }

    private static func plainText(from content: MacClippyPasteboardContent) -> String? {
        switch content {
        case let .text(value):
            return value
        case let .html(_, plainText), let .rtf(_, plainText):
            return plainText
        case .image, .files:
            return nil
        }
    }

    private static func imageRepresentation(for data: Data) -> (typeIdentifier: String, data: Data) {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return ("public.png", data)
        }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return ("public.tiff", data)
        }
        return (MacClippyCardDragPolicy.typeIdentifier(for: .image), data)
    }
}
