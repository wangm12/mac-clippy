import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

import MacClippyCore

public enum MacClippyCapturePayload: Equatable, Sendable {
    case text(String)
    case rtf(Data)
    case html(String)
    case image(data: Data, width: Int, height: Int)
    case files([URL])

    public var searchableText: String? {
        switch self {
        case let .text(value):
            return value
        case let .html(value):
            return MacClippyCaptureMapper.plainText(fromHTML: value)
        case let .rtf(data):
            return MacClippyCaptureMapper.plainText(fromRTF: data)
        case .image, .files:
            return nil
        }
    }
}

/// Materialized once for a pasteboard generation and shared by filtering and
/// persistence. Mapping HTML/RTF/image metadata and walking all advertised
/// representations can be materially more expensive than the surrounding
/// lifecycle bookkeeping, so callers should pass this projection across the
/// observer/runtime boundary instead of rebuilding it.
public struct MacClippyCaptureProjection: Equatable, Sendable {
    public let payload: MacClippyCapturePayload?
    public let representations: [MacClippyClipboardRepresentation]
    public let searchableText: String?

    public init(
        payload: MacClippyCapturePayload?,
        representations: [MacClippyClipboardRepresentation]
    ) {
        self.payload = payload
        self.representations = representations
        searchableText = payload?.searchableText
    }
}

public enum MacClippyCaptureMapper {
    private static let pngType = NSPasteboard.PasteboardType.png.rawValue
    private static let tiffType = NSPasteboard.PasteboardType.tiff.rawValue
    private static let stringType = NSPasteboard.PasteboardType.string.rawValue
    private static let rtfType = NSPasteboard.PasteboardType.rtf.rawValue
    private static let htmlType = NSPasteboard.PasteboardType.html.rawValue
    private static let fileURLType = NSPasteboard.PasteboardType.fileURL.rawValue

    public static func projection(for change: PasteboardChange) -> MacClippyCaptureProjection {
        MacClippyCaptureProjection(
            payload: payload(for: change),
            representations: representations(for: change)
        )
    }

    public static func payload(for change: PasteboardChange) -> MacClippyCapturePayload? {
        if let image = imagePayload(in: change.items) { return image }
        if let text = firstString(for: stringType, in: change.items), !text.isEmpty { return .text(text) }
        if let data = firstData(for: rtfType, in: change.items), !data.isEmpty { return .rtf(data) }
        if let html = firstString(for: htmlType, in: change.items), !html.isEmpty { return .html(html) }

        let fileURLs = change.items.flatMap { item -> [URL] in
            guard let data = item.data(forType: fileURLType) else { return [] }
            return urls(from: data)
        }
        return fileURLs.isEmpty ? nil : .files(fileURLs)
    }

    public static func shouldExclude(_ payload: MacClippyCapturePayload, using blocklist: RegexBlocklist) -> Bool {
        guard let searchableText = payload.searchableText else { return false }
        return blocklist.matches(searchableText)
    }

    // P0 no-filter capture: retain every external NSPasteboard representation
    // (UTI + raw Data), including concealed, transient, custom, unknown, and
    // dynamic UTIs, and including empty advertised payloads and provider-
    // unavailable payloads. The caller is responsible for suppressing only
    // exact internal writes via the pasteboard write sentinel; this mapping
    // never drops a representation based on its UTI or payload availability.
    //
    // Payload states:
    //   - A payload with bytes (possibly empty) is retained as .present.
    //   - A payload whose provider advertised the UTI but returned no Data
    //     (and no string fallback) is retained as .unavailable so the
    //     advertised type is preserved as a type-only marker rather than
    //     silently dropped. The reader's cross-poll retry layer is expected
    //     to have already retried lazy provider data; whatever it could not
    //     materialize is marked unavailable here.
    // Malformed representation data (non-UTF8 strings, undecodable file
    // URLs) is irrelevant here because the mapper never decodes strings; raw
    // bytes are retained verbatim per UTI.
    public static func representations(for change: PasteboardChange) -> [MacClippyClipboardRepresentation] {
        var seen = Set<String>()
        var ordered: [MacClippyClipboardRepresentation] = []

        for item in change.items {
            for type in item.types {
                let uti = type
                guard !seen.contains(uti) else { continue }
                seen.insert(uti)

                let payloadState: MacClippyClipboardRepresentationPayloadState
                let data: Data?

                if let direct = item.data(forType: uti) {
                    payloadState = .present
                    data = direct
                } else if let string = item.string(forType: uti) {
                    payloadState = .present
                    data = Data(string.utf8)
                } else if item.oversizedTypes.contains(uti) {
                    payloadState = .oversized
                    data = nil
                } else {
                    // The provider advertised this UTI but no payload is
                    // available (the reader's cross-poll retry already
                    // exhausted its budget). Retain the UTI as an explicit
                    // .unavailable marker so the advertised type set is
                    // complete and the caller can distinguish a genuinely
                    // empty payload (present, zero bytes) from a missing one.
                    payloadState = .unavailable
                    data = nil
                }

                ordered.append(MacClippyClipboardRepresentation(
                    uti: uti,
                    payloadBytes: data,
                    blobID: nil,
                    payloadState: payloadState
                ))
            }
        }

        return ordered
    }

    // Returns the primary representation slot for a UTI so the runtime can
    // decide which representation drives the existing card/preview/paste path
    // without re-running the priority logic. P0 keeps the legacy payload(for:)
    // as the source of truth for the primary slot; this helper only labels
    // known UTIs so tests and future phases can reason about the slot map.
    public static func slot(forUTI uti: String) -> MacClippyClipboardRepresentationSlot {
        switch uti {
        case stringType: .text
        case rtfType: .rtf
        case htmlType: .html
        case pngType, tiffType: .image
        case fileURLType: .files
        default: .other
        }
    }

    // Best-effort plain-text preview derived from a representation set, used
    // when the legacy payload(for:) mapper could not pick a known primary slot
    // (e.g. only custom/unknown UTIs were present). Tries the public.utf8
    // plain-text slot, then public.html, then public.rtf, then the first
    // UTF8-decodable representation that contains at least one printable
    // character. Returns nil when no text can be derived so the caller can
    // fall back to a generic preview string instead of surfacing binary
    // control bytes as a misleading preview.
    public static func plainText(for representations: [MacClippyClipboardRepresentation]) -> String? {
        if let text = representation(for: stringType, in: representations)?.payloadBytes,
           let decoded = String(data: text, encoding: .utf8),
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return decoded
        }
        if let html = representation(for: htmlType, in: representations)?.payloadBytes,
           let decoded = String(data: html, encoding: .utf8),
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // NSAttributedString(html:) appends a trailing newline; trim it
            // so the preview matches the visible text.
            let plain = plainText(fromHTML: decoded)
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let rtf = representation(for: rtfType, in: representations)?.payloadBytes,
           let decoded = plainText(fromRTF: rtf),
           !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return decoded
        }
        for representation in representations {
            guard let data = representation.payloadBytes,
                  let decoded = String(data: data, encoding: .utf8),
                  containsPrintableCharacter(decoded) else { continue }
            return decoded
        }
        return nil
    }

    // Returns true when the string contains at least one printable (non-
    // whitespace, non-control) character, so binary control-byte payloads are
    // not surfaced as text previews.
    private static func containsPrintableCharacter(_ string: String) -> Bool {
        string.contains { character in
            character.isLetter || character.isNumber || character.isPunctuation || character.isSymbol
        }
    }

    private static func representation(
        for uti: String,
        in representations: [MacClippyClipboardRepresentation]
    ) -> MacClippyClipboardRepresentation? {
        representations.first { $0.uti == uti }
    }

    static func plainText(fromHTML html: String) -> String {
        if let attributed = try? NSAttributedString(
            data: Data(html.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) {
            return attributed.string
        }

        return html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plainText(fromRTF data: Data) -> String? {
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) else { return nil }
        return attributed.string
    }

    private static func imagePayload(in items: [PasteboardItem]) -> MacClippyCapturePayload? {
        for type in [pngType, tiffType] {
            if let data = firstData(for: type, in: items), !data.isEmpty {
                return imagePayload(data: data)
            }
        }

        for item in items {
            for type in item.types.sorted() {
                guard type != pngType, type != tiffType,
                      let data = item.data(forType: type), !data.isEmpty,
                      let uniformType = UTType(type), uniformType.conforms(to: .image) else { continue }
                return imagePayload(data: data)
            }
        }
        return nil
    }

    private static func imagePayload(data: Data) -> MacClippyCapturePayload {
        let properties = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return .image(data: data, width: width, height: height)
    }

    private static func firstData(for type: String, in items: [PasteboardItem]) -> Data? {
        items.lazy.compactMap { $0.data(forType: type) }.first
    }

    private static func firstString(for type: String, in items: [PasteboardItem]) -> String? {
        items.lazy.compactMap { $0.string(forType: type) }.first
    }

    private static func urls(from data: Data) -> [URL] {
        if let url = NSURL(dataRepresentation: data, relativeTo: nil) as URL? { return [url] }
        guard let string = String(data: data, encoding: .utf8) else { return [] }
        return string
            .split(whereSeparator: \.isNewline)
            .compactMap { URL(string: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
