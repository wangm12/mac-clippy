import AppKit
import SwiftUI
import UniformTypeIdentifiers

import MacClippyCore
import MacClippyPlatform

private final class MacClippyCardDragPayloadCache: @unchecked Sendable {
    private let lock = NSLock()
    private let loader: () throws -> [MacClippyCardDragRepresentation: MacClippyCardDragPayload]
    private var result: Result<[MacClippyCardDragRepresentation: MacClippyCardDragPayload], Error>?

    init(
        loader: @escaping () throws -> [MacClippyCardDragRepresentation: MacClippyCardDragPayload]
    ) {
        self.loader = loader
    }

    func payload(for representation: MacClippyCardDragRepresentation) throws -> MacClippyCardDragPayload? {
        lock.lock()
        defer { lock.unlock() }
        if result == nil {
            result = Result { try loader() }
        }
        return try result?.get()[representation]
    }
}

struct MacClippyCardDragPreview: View {
    let context: MacClippyClipboardCardContext
    let thumbnail: CGImage?

    private var item: MacClippyHistoryEntry { context.item }

    private var typeLabel: String {
        switch item.contentKind {
        case .text:
            return "TEXT"
        case .html:
            return "HTML"
        case .rtf:
            return "RICH TEXT"
        case .image:
            return "IMAGE"
        case .files:
            guard let url = item.fileURLs.first else { return "FILE" }
            if item.fileURLs.count > 1 {
                return "FILES +\(item.fileURLs.count - 1)"
            }
            let fileExtension = url.pathExtension
            return fileExtension.isEmpty ? "FILE" : String(fileExtension.prefix(6)).uppercased()
        }
    }

    private var symbolName: String {
        switch item.contentKind {
        case .text:
            return "text.alignleft"
        case .html:
            return "chevron.left.forwardslash.chevron.right"
        case .rtf:
            return "textformat"
        case .image:
            return "photo"
        case .files:
            guard let url = item.fileURLs.first else { return "doc" }
            switch MacClippyFilePresentation.mediaKind(for: url) {
            case .image:
                return "photo"
            case .movie:
                return "film"
            case .other:
                switch url.pathExtension.lowercased() {
                case "pdf": return "doc.text"
                case "csv", "tsv", "xls", "xlsx", "numbers": return "tablecells"
                case "zip", "rar", "7z", "tar", "gz": return "archivebox"
                case "mp3", "m4a", "wav", "aif", "aiff": return "waveform"
                case "doc", "docx", "pages", "rtf", "txt", "md": return "doc.richtext"
                default: return "doc"
                }
            }
        }
    }

    private var contentSlice: String {
        let text: String
        switch item.contentKind {
        case .text, .html, .rtf:
            let preview = item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
            text = preview.isEmpty ? item.displayTitle : preview
        case .image, .files:
            text = MacClippyDockCardVisibleNamePolicy.text(for: item)
        }
        return String(text.prefix(120))
    }

    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            previewMedia
                .frame(width: 38, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            Text(typeLabel)
                .font(.system(size: 5.5, weight: .bold))
                .tracking(0.25)
                .foregroundStyle(Color(nsColor: context.source.accent))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(contentSlice)
                .font(.system(size: 6.5, weight: .medium))
                .foregroundStyle(MacClippyDockTheme.textColor)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(4)
        .frame(width: 46, height: 72)
        .background(
            MacClippyDockTheme.sourceCardBackground(
                accent: context.source.accent,
                elevated: false,
                in: previewShape
            )
            .opacity(0.82)
        )
        .clipShape(previewShape)
        .overlay {
            previewShape.strokeBorder(.white.opacity(0.24), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.14), radius: 4, x: 0, y: 2)
        .opacity(0.88)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var previewMedia: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1, orientation: .up)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(nsColor: context.source.accent).opacity(0.12))
                .overlay {
                    Image(systemName: symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(nsColor: context.source.accent))
                }
        }
    }
}

extension MacClippyDockView {
    func cardDragProvider(for item: MacClippyHistoryEntry) -> NSItemProvider {
        let provider = NSItemProvider()
        let representations = MacClippyCardDragPolicy.representations(for: item.contentKind)
        let contentRepresentations = representations.filter { $0 != .recordID }
        let runtime = model.runtime
        let payloadCache = MacClippyCardDragPayloadCache {
            try runtime.dragPayloads(id: item.id, representations: contentRepresentations)
        }
        for representation in representations {
            registerCardDragRepresentation(
                representation,
                item: item,
                payloadCache: payloadCache,
                on: provider
            )
        }
        return provider
    }

    private func registerCardDragRepresentation(
        _ representation: MacClippyCardDragRepresentation,
        item: MacClippyHistoryEntry,
        payloadCache: MacClippyCardDragPayloadCache,
        on provider: NSItemProvider
    ) {
        if representation == .recordID {
            provider.registerDataRepresentation(
                forTypeIdentifier: MacClippyCardDragPolicy.recordTypeIdentifier,
                visibility: .all
            ) { completion in
                completion(Data(item.id.rawValue.utf8), nil)
                return nil
            }
            return
        }
        if representation == .fileURL {
            registerCardDragFileURLs(item.fileURLs, payloadCache: payloadCache, on: provider)
            return
        }

        let typeIdentifiers: [String]
        if representation == .image {
            // The export policy supplies canonical PNG bytes for every image.
            typeIdentifiers = [UTType.png.identifier]
        } else {
            typeIdentifiers = [MacClippyCardDragPolicy.typeIdentifier(for: representation)]
        }

        for typeIdentifier in typeIdentifiers {
            provider.registerDataRepresentation(
                forTypeIdentifier: typeIdentifier,
                visibility: .all
            ) { completion in
                do {
                    guard let payload = try payloadCache.payload(for: representation) else {
                        completion(nil, nil)
                        return nil
                    }
                    guard payload.typeIdentifier == typeIdentifier else {
                        completion(nil, nil)
                        return nil
                    }
                    completion(payload.data, nil)
                } catch {
                    completion(nil, error)
                }
                return nil
            }
        }
    }

    private func registerCardDragFileURLs(
        _ urls: [URL],
        payloadCache: MacClippyCardDragPayloadCache,
        on provider: NSItemProvider
    ) {
        // NSItemProvider represents one dragged item. Registering each URL on
        // the same provider makes same-extension files overwrite one another
        // and makes different extensions look like alternate formats of one
        // file. Use the first file consistently until the source creates one
        // provider per native dragging item.
        guard let url = urls.first else { return }
        let typeIdentifier = UTType(filenameExtension: url.pathExtension)?.identifier
            ?? UTType.data.identifier
        provider.registerFileRepresentation(
            forTypeIdentifier: typeIdentifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(url, false, nil)
            return nil
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: MacClippyCardDragPolicy.typeIdentifier(for: .fileURL),
            visibility: .all
        ) { completion in
            do {
                guard let payload = try payloadCache.payload(for: .fileURL) else {
                    completion(nil, nil)
                    return nil
                }
                completion(payload.data, nil)
            } catch {
                completion(nil, error)
            }
            return nil
        }
    }

}
