import AppKit
import CoreGraphics
import CryptoKit
import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    func entry(for meta: ClipboardItemMeta) throws -> MacClippyHistoryEntry? {
        let key = cacheKey(for: meta)
        if let cached = historyEntryCache.object(forKey: key) {
            return cached.entry
        }
        let body: ClipboardRecord
        do {
            body = try clipboardStore.body(for: meta.id)
        } catch {
            if isCorruptStoredRecord(error) {
                recordCorruptStoredRecord(operation: "history_record_decode")
                return nil
            }
            if case MacClippyStoreError.recordNotFound = error {
                return nil
            }
            throw error
        }
        guard meta.contentKind == nil || meta.contentKind == body.contentKind else {
            recordCorruptStoredRecord(operation: "history_content_kind_mismatch")
            return nil
        }
        let projected = entry(for: meta, body: body)
        let entry = try stampRemoteClipboard([meta.id: projected], metas: [meta])[meta.id] ?? projected
        historyEntryCache.setObject(
            MacClippyHistoryEntryCacheBox(entry),
            forKey: key,
            cost: historyEntryCacheCost(entry)
        )
        return entry
    }

    func cacheKey(for meta: ClipboardItemMeta) -> NSString {
        let label = meta.customLabel ?? ""
        let ocrFingerprint = meta.ocrText.map(Self.ocrFingerprint) ?? ""
        let lastAccessed = meta.lastAccessed?.timeIntervalSince1970 ?? 0
        return [
            meta.id.rawValue,
            "\(meta.lamport)",
            "\(meta.modified.timeIntervalSince1970)",
            meta.preview,
            label,
            ocrFingerprint,
            "\(meta.frequency)",
            "\(lastAccessed)"
        ].joined(separator: "#") as NSString
    }

    private static func ocrFingerprint(_ text: String) -> String {
        let bounded = String(
            bytes: text.utf8.prefix(MacClippyCollectionLimits.maxOCRTextUTF8Bytes),
            encoding: .utf8
        ) ?? ""
        return SHA256.hash(data: Data(bounded.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func historyEntryCacheCost(_ entry: MacClippyHistoryEntry) -> Int {
        let previewBytes = entry.preview.utf8.count
        let labelBytes = entry.meta.customLabel?.utf8.count ?? 0
        let ocrBytes = entry.meta.ocrText?.utf8.count ?? 0
        let fileURLBytes = entry.fileURLs.reduce(0) { total, url in
            total + url.absoluteString.utf8.count
        }
        return max(1, previewBytes + labelBytes + ocrBytes + fileURLBytes)
    }

    func entry(for meta: ClipboardItemMeta, body: ClipboardRecord) -> MacClippyHistoryEntry {
        let preview: String
        switch body {
        case let .text(value):
            preview = String(value.prefix(2_000))
        case .html, .rtf:
            // Capture already stored a stripped preview. Re-parsing the full
            // HTML/RTF body here would allocate an NSAttributedString for
            // every card on every history page.
            preview = String(meta.preview.prefix(2_000))
        case .image, .encryptedImage:
            if let ocrText = meta.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !ocrText.isEmpty {
                preview = ocrText.count > 2_000
                    ? String(ocrText.prefix(2_000)) + " …"
                    : ocrText
            } else {
                preview = String(meta.preview.prefix(2_000))
            }
        case .files:
            preview = String(
                MacClippyFilePresentation.displayPreview(fromStoredPreview: meta.preview)
                    .prefix(2_000)
            )
        }

        let fileURLs: [URL]
        let imageDimensions: CGSize?
        switch body {
        case let .files(urls):
            fileURLs = urls
            imageDimensions = nil
        case let .image(_, width, height), let .encryptedImage(_, width, height):
            fileURLs = []
            imageDimensions = CGSize(width: width, height: height)
        default:
            fileURLs = []
            imageDimensions = nil
        }
        return MacClippyHistoryEntry(
            meta: meta,
            contentKind: body.contentKind,
            preview: preview,
            fileURLs: fileURLs,
            imageDimensions: imageDimensions
        )
    }

    func pasteboardContent(
        for record: ClipboardRecord,
        plain: Bool
    ) throws -> MacClippyPasteboardContent {
        switch record {
        case let .text(value):
            return .text(value)
        case let .html(value):
            let text = MacClippyClipboardText.plainText(from: record) ?? value
            return plain ? .text(text) : .html(value, plainText: text)
        case let .rtf(data):
            guard let text = MacClippyClipboardText.plainText(from: record) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return plain ? .text(text) : .rtf(data, plainText: text)
        case let .image(blobID, _, _), let .encryptedImage(blobID, _, _):
            return .image(try blobStore.read(id: blobID))
        case let .files(urls):
            return .files(urls)
        }
    }

    func pasteboardContent(
        for snapshot: MacClippyClipboardPlaybackSnapshot,
        plain: Bool
    ) throws -> MacClippyPasteboardContent {
        if plain {
            return try pasteboardContent(for: snapshot.record, plain: true)
        }
        guard !snapshot.representations.isEmpty else {
            return try pasteboardContent(for: snapshot.record, plain: false)
        }

        struct ItemBuilder {
            var types: [String] = []
            var representations: [String: Data] = [:]
        }
        var builders: [Int: ItemBuilder] = [:]
        for representation in snapshot.representations {
            guard let bytes = try pasteboardBytes(for: representation) else { continue }
            var item = builders[representation.itemIndex, default: ItemBuilder()]
            guard item.representations[representation.uti] == nil else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            item.types.append(representation.uti)
            item.representations[representation.uti] = bytes
            builders[representation.itemIndex] = item
        }
        let items = builders.keys.sorted().compactMap { index -> PasteboardItem? in
            guard let item = builders[index], !item.types.isEmpty else { return nil }
            return PasteboardItem(types: item.types, representations: item.representations)
        }
        guard !items.isEmpty else { throw MacClippyStoreError.invalidStoredRecord }
        return .items(items)
    }

    private func pasteboardBytes(
        for representation: MacClippyClipboardRepresentation
    ) throws -> Data? {
        switch representation.payloadState {
        case .present:
            guard let payload = representation.payloadBytes, representation.blobID == nil else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return payload
        case .spilled:
            guard let blobID = representation.blobID, representation.payloadBytes == nil else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return try blobStore.read(
                id: blobID,
                maxBytes: MacClippyPasteboardInputLimits.default.maxRepresentationBytes
            )
        case .unavailable, .oversized:
            return nil
        }
    }
}
