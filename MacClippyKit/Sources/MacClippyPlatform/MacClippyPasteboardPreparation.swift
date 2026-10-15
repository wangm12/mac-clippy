import AppKit
import Foundation

public enum MacClippyPasteboardContent: Equatable, Sendable {
    case text(String)
    case html(String, plainText: String)
    case rtf(Data, plainText: String)
    case image(Data)
    case files([URL])
    case items([PasteboardItem])
}

public enum MacClippyPasteboardPreparer {
    /// Production pasteboard writes must call this only through
    /// `MacClippyPasteInjector`'s `preparer` closure so snapshot/restore
    /// protections stay centralized. Tests may call it directly.
    @discardableResult
    public static func prepare(
        _ content: MacClippyPasteboardContent,
        on pasteboard: NSPasteboard
    ) -> Bool {
        guard (try? MacClippyNativePasteboard.clear(pasteboard)) != nil else { return false }
        return prepareContent(content, on: pasteboard)
    }

    private static func prepareContent(
        _ content: MacClippyPasteboardContent,
        on pasteboard: NSPasteboard
    ) -> Bool {
        switch content {
        case let .text(value):
            return writeText(value, to: pasteboard)
        case let .html(value, plainText):
            return writeHTML(value, plainText: plainText, to: pasteboard)
        case let .rtf(data, plainText):
            return writeRTF(data, plainText: plainText, to: pasteboard)
        case let .image(data):
            return writeImage(data, to: pasteboard)
        case let .files(urls):
            return writeFiles(urls, to: pasteboard)
        case let .items(items):
            return writeItems(items, to: pasteboard)
        }
    }

    private static func writeText(_ value: String, to pasteboard: NSPasteboard) -> Bool {
        writeSingleItem(to: pasteboard) { item in
            try MacClippyNativePasteboard.set(value, on: item, forType: .string)
        }
    }

    private static func writeHTML(
        _ value: String,
        plainText: String,
        to pasteboard: NSPasteboard
    ) -> Bool {
        writeSingleItem(to: pasteboard) { item in
            try MacClippyNativePasteboard.set(plainText, on: item, forType: .string)
                && MacClippyNativePasteboard.set(value, on: item, forType: .html)
        }
    }

    private static func writeRTF(
        _ data: Data,
        plainText: String,
        to pasteboard: NSPasteboard
    ) -> Bool {
        writeSingleItem(to: pasteboard) { item in
            try MacClippyNativePasteboard.set(plainText, on: item, forType: .string)
                && MacClippyNativePasteboard.set(data, on: item, forType: .rtf)
        }
    }

    private static func writeImage(_ data: Data, to pasteboard: NSPasteboard) -> Bool {
        let representation = imageRepresentation(for: data)
        return writeSingleItem(to: pasteboard) { item in
            try MacClippyNativePasteboard.set(
                representation.data,
                on: item,
                forType: representation.type
            )
        }
    }

    private static func writeFiles(_ urls: [URL], to pasteboard: NSPasteboard) -> Bool {
        (try? MacClippyNativePasteboard.write(urls as [NSURL], to: pasteboard)) ?? false
    }

    private static func writeItems(_ items: [PasteboardItem], to pasteboard: NSPasteboard) -> Bool {
        let nativeItems = items.compactMap(makeNativeItem)
        guard !nativeItems.isEmpty, nativeItems.count == items.count else { return false }
        return (try? MacClippyNativePasteboard.write(nativeItems, to: pasteboard)) ?? false
    }

    private static func makeNativeItem(_ source: PasteboardItem) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        for type in source.types {
            guard let data = source.data(forType: type) else { continue }
            guard (try? MacClippyNativePasteboard.set(
                data,
                on: item,
                forType: NSPasteboard.PasteboardType(type)
            )) == true else { return nil }
        }
        return item
    }

    private static func writeSingleItem(
        to pasteboard: NSPasteboard,
        configure: (NSPasteboardItem) throws -> Bool
    ) -> Bool {
        guard let item = makeItem(configure) else { return false }
        return (try? MacClippyNativePasteboard.write([item], to: pasteboard)) ?? false
    }

    private static func makeItem(
        _ configure: (NSPasteboardItem) throws -> Bool
    ) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        guard (try? configure(item)) == true else { return nil }
        return item
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
