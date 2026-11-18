import Foundation
import ImageIO
import UniformTypeIdentifiers

import MacClippyCore

public enum MacClippyCardDragExportError: Error, LocalizedError {
    case invalidImageData
    case imageEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidImageData:
            "The clipboard image could not be decoded."
        case .imageEncodingFailed:
            "The clipboard image could not be encoded as PNG."
        }
    }
}

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
        try? payloadThrowing(for: representation, recordID: recordID, content: content)
    }

    /// Resolves a drag payload and preserves image conversion failures so the
    /// NSItemProvider can report them to the requesting app.
    public static func payloadThrowing(
        for representation: MacClippyCardDragRepresentation,
        recordID: RecordID,
        content: MacClippyPasteboardContent
    ) throws -> MacClippyCardDragPayload? {
        switch representation {
        case .recordID:
            return recordPayload(recordID)
        case .plainText:
            return plainTextPayload(from: content)
        case .rtf:
            return rtfPayload(from: content)
        case .html:
            return htmlPayload(from: content)
        case .image:
            return try imagePayload(from: content)
        case .fileURL:
            return fileURLPayload(from: content)
        }
    }

    private static func recordPayload(_ id: RecordID) -> MacClippyCardDragPayload {
        MacClippyCardDragPayload(
            typeIdentifier: MacClippyCardDragPolicy.recordTypeIdentifier,
            data: Data(id.rawValue.utf8)
        )
    }

    private static func plainTextPayload(from content: MacClippyPasteboardContent) -> MacClippyCardDragPayload? {
        guard let text = plainText(from: content) else { return nil }
        return MacClippyCardDragPayload(
            typeIdentifier: MacClippyCardDragPolicy.typeIdentifier(for: .plainText),
            data: Data(text.utf8)
        )
    }

    private static func rtfPayload(from content: MacClippyPasteboardContent) -> MacClippyCardDragPayload? {
        let data: Data
        switch content {
        case let .rtf(value, _):
            data = value
        case let .items(items):
            guard let value = firstData(for: "public.rtf", in: items) else { return nil }
            data = value
        default:
            return nil
        }
        return MacClippyCardDragPayload(
            typeIdentifier: MacClippyCardDragPolicy.typeIdentifier(for: .rtf),
            data: data
        )
    }

    private static func htmlPayload(from content: MacClippyPasteboardContent) -> MacClippyCardDragPayload? {
        let html: String
        switch content {
        case let .html(value, _):
            html = value
        case let .items(items):
            guard let data = firstData(for: "public.html", in: items),
                  let value = String(data: data, encoding: .utf8) else { return nil }
            html = value
        default:
            return nil
        }
        return MacClippyCardDragPayload(
            typeIdentifier: MacClippyCardDragPolicy.typeIdentifier(for: .html),
            data: Data(html.utf8)
        )
    }

    private static func imagePayload(from content: MacClippyPasteboardContent) throws -> MacClippyCardDragPayload? {
        let candidates: [Data]
        switch content {
        case let .image(value):
            candidates = [value]
        case let .items(items):
            candidates = imageDataCandidates(in: items)
        default:
            return nil
        }
        guard !candidates.isEmpty else { return nil }

        var lastError: Error?
        for data in candidates {
            do {
                return MacClippyCardDragPayload(
                    typeIdentifier: UTType.png.identifier,
                    data: try pngRepresentation(for: data)
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? MacClippyCardDragExportError.invalidImageData
    }

    private static func fileURLPayload(from content: MacClippyPasteboardContent) -> MacClippyCardDragPayload? {
        let data: Data
        switch content {
        case let .files(urls):
            guard let url = urls.first else { return nil }
            data = Data(url.absoluteString.utf8)
        case let .items(items):
            guard let value = firstData(for: "public.file-url", in: items) else { return nil }
            data = value
        default:
            return nil
        }
        return MacClippyCardDragPayload(
            typeIdentifier: MacClippyCardDragPolicy.typeIdentifier(for: .fileURL),
            data: data
        )
    }

    private static func plainText(from content: MacClippyPasteboardContent) -> String? {
        switch content {
        case let .text(value):
            return value
        case let .html(_, plainText), let .rtf(_, plainText):
            return plainText
        case let .items(items):
            if let data = firstData(for: "public.utf8-plain-text", in: items),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            if let data = firstData(for: "public.html", in: items),
               let html = String(data: data, encoding: .utf8) {
                return MacClippyClipboardText.plainText(from: .html(html))
            }
            if let data = firstData(for: "public.rtf", in: items) {
                return MacClippyClipboardText.plainText(from: .rtf(data))
            }
            return nil
        case .image, .files:
            return nil
        }
    }

    private static func firstData(for uti: String, in items: [PasteboardItem]) -> Data? {
        items.first { $0.data(forType: uti) != nil }?.data(forType: uti)
    }

    private static func firstData(for utis: [String], in items: [PasteboardItem]) -> Data? {
        for item in items {
            for uti in utis {
                if let data = item.data(forType: uti) { return data }
            }
        }
        return nil
    }

    private static func imageDataCandidates(in items: [PasteboardItem]) -> [Data] {
        var result: [Data] = []
        for item in items {
            let imageTypes = item.types
                .filter { UTType($0)?.conforms(to: .image) == true }
                .sorted { lhs, rhs in
                    lhs == UTType.png.identifier && rhs != UTType.png.identifier
                }
            for type in imageTypes {
                if let data = item.data(forType: type) { result.append(data) }
            }
        }
        return result
    }

    private static func pngRepresentation(for data: Data) throws -> Data {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return data
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source),
              UTType(sourceType as String)?.conforms(to: .image) == true,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MacClippyCardDragExportError.invalidImageData
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw MacClippyCardDragExportError.imageEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MacClippyCardDragExportError.imageEncodingFailed
        }
        return output as Data
    }
}
