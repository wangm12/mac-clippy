import AppKit
import Foundation

public enum MacClippyPasteboardContent: Equatable, Sendable {
    case text(String)
    case html(String, plainText: String)
    case rtf(Data, plainText: String)
    case image(Data)
    case files([URL])
}

public enum MacClippyPasteboardPreparer {
    @discardableResult
    public static func prepare(
        _ content: MacClippyPasteboardContent,
        on pasteboard: NSPasteboard
    ) -> Bool {
        pasteboard.clearContents()

        switch content {
        case let .text(value):
            return pasteboard.setString(value, forType: .string)
        case let .html(value, plainText):
            return pasteboard.setString(plainText, forType: .string)
                && pasteboard.setString(value, forType: .html)
        case let .rtf(data, plainText):
            return pasteboard.setString(plainText, forType: .string)
                && pasteboard.setData(data, forType: .rtf)
        case let .image(data):
            let representation = imageRepresentation(for: data)
            return pasteboard.setData(representation.data, forType: representation.type)
        case let .files(urls):
            return pasteboard.writeObjects(urls as [NSURL])
        }
    }

    private static func imageRepresentation(for data: Data) -> (data: Data, type: NSPasteboard.PasteboardType) {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return (data, .png)
        }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) || data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return (data, .tiff)
        }
        if let tiffData = NSImage(data: data)?.tiffRepresentation {
            return (tiffData, .tiff)
        }
        return (data, .png)
    }
}
