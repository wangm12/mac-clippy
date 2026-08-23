import AppKit
import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    // A preview is a user-facing, downsampled presentation. Keep its source
    // read bounded just like the thumbnail path so opening Space cannot
    // allocate an arbitrarily large decrypted image.
    private static let previewImageReadLimit = 128 * 1_024 * 1_024

    // Classification and pretty-printing are bounded by the same limit that
    // caps the rendered text, so a multi-megabyte clip is never parsed for a
    // payload the preview would truncate anyway.
    private static let previewClassificationLimit = MacClippyDockPreviewTextPolicy.maxRenderedCharacters

    // What a preview needs out of the store. Reading stops at the raw record
    // so decoding and classification can run without the store lock held.
    private enum PreviewSource {
        case text(String)
        case html(String)
        case rtf(Data)
        case image(Data)
        case files([URL])
    }

    func preview(id: RecordID) throws -> MacClippyRuntimePreviewPayload {
        let source = try withStoreLock { () -> PreviewSource in
            switch try clipboardStore.body(for: id) {
            case let .text(value):
                return .text(value)
            case let .html(value):
                return .html(value)
            case let .rtf(data):
                return .rtf(data)
            case let .image(blobID, _, _), let .encryptedImage(blobID, _, _):
                return .image(try blobStore.read(id: blobID, maxBytes: Self.previewImageReadLimit))
            case let .files(urls):
                return .files(urls)
            }
        }
        return try previewPayload(for: source)
    }

    func preview(snippetID: RecordID) throws -> MacClippyRuntimePreviewPayload {
        let body = try withStoreLock { try snippetStore.fetch(id: snippetID).body }
        return previewTextPayload(body)
    }

    // Runs after the store lock is released: attributed-string decoding, text
    // classification, and pretty-printing are all proportional to the payload
    // size and must not block capture or history queries.
    private func previewPayload(for source: PreviewSource) throws -> MacClippyRuntimePreviewPayload {
        switch source {
        case let .text(value):
            return previewTextPayload(value)
        case let .html(value):
            let record = ClipboardRecord.html(value)
            if let attributed = MacClippyClipboardText.attributedString(from: record) {
                return previewRichTextPayload(attributed)
            }
            return previewTextPayload(MacClippyClipboardText.plainText(from: record) ?? value)
        case let .rtf(data):
            return try previewRTFPayload(data)
        case let .image(data):
            return .image(data)
        case let .files(urls):
            return .files(urls)
        }
    }

    private func previewRTFPayload(_ data: Data) throws -> MacClippyRuntimePreviewPayload {
        let record = ClipboardRecord.rtf(data)
        if let attributed = MacClippyClipboardText.attributedString(from: record) {
            return previewRichTextPayload(attributed)
        }
        guard let text = MacClippyClipboardText.plainText(from: record) else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        return previewTextPayload(text)
    }

    private func previewTextPayload(_ text: String) -> MacClippyRuntimePreviewPayload {
        let classificationSource = String(text.prefix(Self.previewClassificationLimit))
        let kind = MacClippyClipboardPresentation.kind(forPlainText: classificationSource)
        // A truncated payload cannot parse as JSON, so `kind` is only `.json`
        // when the bounded prefix is the whole document.
        let displayText = kind == .json
            ? TextTransform.prettyJSON.apply(to: classificationSource)
            : classificationSource
        return .text(
            MacClippyRuntimePreviewText(
                displayText: MacClippyDockPreviewTextPolicy.displayText(
                    for: displayText,
                    totalCharacterCount: text.count
                ),
                characterCount: text.count,
                kind: kind
            )
        )
    }

    private func previewRichTextPayload(_ attributed: NSAttributedString) -> MacClippyRuntimePreviewPayload {
        let plain = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayPlain = MacClippyDockPreviewTextPolicy.displayText(for: plain)
        let displayAttributed = previewDisplayAttributed(
            attributed,
            plain: plain,
            displayPlain: displayPlain
        )
        return .richText(
            MacClippyPreviewRichText(displayAttributed),
            plain: displayPlain,
            characterCount: plain.count
        )
    }

    private func previewDisplayAttributed(
        _ attributed: NSAttributedString,
        plain: String,
        displayPlain: String
    ) -> NSAttributedString {
        guard displayPlain != plain else { return attributed }
        let source = attributed.string
        let start = source.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)?.lowerBound
            ?? source.startIndex
        let trimmedEnd = source.rangeOfCharacter(
            from: .whitespacesAndNewlines.inverted,
            options: .backwards
        )?.upperBound ?? source.endIndex
        let prefixEnd = source.index(
            start,
            offsetBy: MacClippyDockPreviewTextPolicy.maxRenderedCharacters,
            limitedBy: trimmedEnd
        ) ?? trimmedEnd
        let prefixRange = NSRange(start..<prefixEnd, in: source)
        let mutable = NSMutableAttributedString(
            attributedString: attributed.attributedSubstring(from: prefixRange)
        )
        mutable.append(NSAttributedString(
            string: String(displayPlain.dropFirst(MacClippyDockPreviewTextPolicy.maxRenderedCharacters))
        ))
        return mutable
    }
}
