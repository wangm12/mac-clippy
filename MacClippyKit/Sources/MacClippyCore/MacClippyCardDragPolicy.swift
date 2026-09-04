import Foundation

public enum MacClippyCardDragRepresentation: Equatable, Sendable {
    case recordID
    case plainText
    case rtf
    case html
    case image
    case fileURL
}

/// Cards drag a private record-id for pinboard/snippet drops, plus the
/// public types other apps expect. The record id must never ride on
/// `public.utf8-plain-text` or dropping a text card onto Notes would
/// paste a UUID.
public enum MacClippyCardDragPolicy {
    public static let recordTypeIdentifier = "com.macallyouneed.macclippy.record-id"

    public static func representations(
        for kind: MacClippyContentKind
    ) -> [MacClippyCardDragRepresentation] {
        switch kind {
        case .text:
            return [.recordID, .plainText]
        case .rtf:
            return [.recordID, .rtf, .plainText]
        case .html:
            return [.recordID, .html, .plainText]
        case .image:
            return [.recordID, .image]
        case .files:
            return [.recordID, .fileURL]
        }
    }

    public static func typeIdentifier(
        for representation: MacClippyCardDragRepresentation
    ) -> String {
        switch representation {
        case .recordID:
            return recordTypeIdentifier
        case .plainText:
            return "public.utf8-plain-text"
        case .rtf:
            return "public.rtf"
        case .html:
            return "public.html"
        case .image:
            return "public.png"
        case .fileURL:
            return "public.file-url"
        }
    }
}
