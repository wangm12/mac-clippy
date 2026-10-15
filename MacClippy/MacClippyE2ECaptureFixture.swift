#if MACCLIPPY_E2E
import AppKit
import CryptoKit
import Darwin
import Foundation
@_spi(Testing) import MacClippyPlatform

struct MacClippyE2ECaptureExpectation {
    let format: String
    let uti: NSPasteboard.PasteboardType
    let payload: Data
    let expectedPlainText: String?
    let fixtureFileByteCount: Int
}

enum MacClippyE2ECaptureFixtureBuilder {
    static func write(
        request: MacClippyE2EControlRequest,
        isolation: MacClippyE2EIsolation
    ) throws -> MacClippyE2ECaptureExpectation {
        guard let token = request.token,
              let text = request.text,
              text.utf8.count <= 1_048_576 else {
            throw MacClippyE2ECaptureError.invalidRequest
        }
        let format = request.payloadKind ?? request.format ?? "text"
        let payload = try primaryPayload(
            format: format,
            token: token,
            text: text,
            request: request,
            isolation: isolation
        )
        let itemCount = min(max(request.itemCount ?? 1, 1), 4)
        let pasteboardItems = try (0..<itemCount).map { index in
            try makePasteboardItem(
                index: index,
                itemCount: itemCount,
                repeatPrimaryUTI: request.repeatPrimaryUTI ?? false,
                token: token,
                expectation: payload
            )
        }
        return try isolation.pasteboardAccessCoordinator.withAccess {
            try MacClippyNativePasteboard.clear(isolation.pasteboard)
            guard try MacClippyNativePasteboard.write(pasteboardItems, to: isolation.pasteboard) else {
                throw MacClippyE2ECaptureError.pasteboardWriteFailed
            }
            guard let firstItem = try MacClippyNativePasteboard.items(of: isolation.pasteboard).first,
                  let observedPayload = try MacClippyNativePasteboard.data(from: firstItem, forType: payload.uti) else {
                throw MacClippyE2ECaptureError.payloadCreationFailed
            }
            return MacClippyE2ECaptureExpectation(
                format: payload.format,
                uti: payload.uti,
                payload: observedPayload,
                expectedPlainText: payload.expectedPlainText,
                fixtureFileByteCount: payload.fixtureFileByteCount
            )
        }
    }

    private static func primaryPayload(
        format: String,
        token: String,
        text: String,
        request: MacClippyE2EControlRequest,
        isolation: MacClippyE2EIsolation
    ) throws -> MacClippyE2ECaptureExpectation {
        switch format {
        case "text":
            return MacClippyE2ECaptureExpectation(
                format: format,
                uti: .string,
                payload: Data(text.utf8),
                expectedPlainText: text,
                fixtureFileByteCount: 0
            )
        case "html":
            return MacClippyE2ECaptureExpectation(
                format: format,
                uti: .html,
                payload: Data(text.utf8),
                expectedPlainText: plainText(fromHTML: text),
                fixtureFileByteCount: 0
            )
        case "rtf":
            return MacClippyE2ECaptureExpectation(
                format: format,
                uti: .rtf,
                payload: try rtfData(for: text),
                expectedPlainText: text,
                fixtureFileByteCount: 0
            )
        case "image":
            return MacClippyE2ECaptureExpectation(
                format: format,
                uti: .png,
                payload: try pngData(for: token),
                expectedPlainText: nil,
                fixtureFileByteCount: 0
            )
        case "files":
            let count = min(max(request.fileByteCount ?? 128, 32), 4_096)
            let url = try writeFileFixture(token: token, byteCount: count, rootURL: isolation.rootURL)
            return MacClippyE2ECaptureExpectation(
                format: format,
                uti: .fileURL,
                payload: (url as NSURL).dataRepresentation,
                expectedPlainText: nil,
                fixtureFileByteCount: count
            )
        default:
            throw MacClippyE2ECaptureError.unsupportedFormat
        }
    }

    private static func rtfData(for text: String) throws -> Data {
        let attributed = NSAttributedString(string: text)
        guard let data = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else {
            throw MacClippyE2ECaptureError.payloadCreationFailed
        }
        return data
    }

    private static func makePasteboardItem(
        index: Int,
        itemCount: Int,
        repeatPrimaryUTI: Bool,
        token: String,
        expectation: MacClippyE2ECaptureExpectation
    ) throws -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if index == 0 || repeatPrimaryUTI {
            guard try MacClippyNativePasteboard.set(expectation.payload, on: item, forType: expectation.uti) else {
                throw MacClippyE2ECaptureError.payloadCreationFailed
            }
        } else {
            let marker = NSPasteboard.PasteboardType("com.macallyouneed.macclippy.e2e.fixture-index")
            guard try MacClippyNativePasteboard.set("\(token)-item-\(index)", on: item, forType: marker) else {
                throw MacClippyE2ECaptureError.payloadCreationFailed
            }
        }
        if itemCount == 1, repeatPrimaryUTI {
            throw MacClippyE2ECaptureError.invalidRequest
        }
        return item
    }

    private static func pngData(for token: String) throws -> Data {
        let digest = Array(SHA256.hash(data: Data(token.utf8)))
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 16 * 4,
            bitsPerPixel: 32
        )
        guard let representation, let bitmapData = representation.bitmapData else {
            throw MacClippyE2ECaptureError.payloadCreationFailed
        }
        for pixelRow in 0..<16 {
            for pixelColumn in 0..<16 {
                let pixelIndex = pixelRow * 16 + pixelColumn
                let byteIndex = pixelRow * representation.bytesPerRow + pixelColumn * 4
                bitmapData[byteIndex] = digest[(pixelIndex * 3) % digest.count]
                bitmapData[byteIndex + 1] = digest[(pixelIndex * 3 + 1) % digest.count]
                bitmapData[byteIndex + 2] = digest[(pixelIndex * 3 + 2) % digest.count]
                bitmapData[byteIndex + 3] = 0xff
            }
        }
        guard let data = representation.representation(using: .png, properties: [:]), !data.isEmpty else {
            throw MacClippyE2ECaptureError.payloadCreationFailed
        }
        return data
    }

    private static func plainText(fromHTML html: String) -> String {
        guard let attributed = try? NSAttributedString(
            data: Data(html.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) else {
            return html
        }
        return attributed.string
    }

    private static func writeFileFixture(token: String, byteCount: Int, rootURL: URL) throws -> URL {
        let directory = rootURL.appendingPathComponent("corpus-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("\(token).txt", isDirectory: false)
        var bytes = Data("MacClippy E2E file fixture \(token) ".utf8)
        if bytes.count < byteCount {
            bytes.append(Data(repeating: 0x78, count: byteCount - bytes.count))
        } else if bytes.count > byteCount {
            bytes = Data(bytes.prefix(byteCount))
        }
        try bytes.write(to: url, options: .atomic)
        guard chmod(url.path, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw MacClippyE2ECaptureError.payloadCreationFailed
        }
        return url
    }
}

enum MacClippyE2ECaptureError: Error {
    case invalidRequest
    case unsupportedFormat
    case payloadCreationFailed
    case pasteboardWriteFailed
}
#endif
