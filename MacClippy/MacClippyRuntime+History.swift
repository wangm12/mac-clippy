import AppKit
import CoreGraphics
import Foundation

import MacClippyCore
import MacClippyPlatform

private struct MacClippyRuntimeDetailsSnapshot {
    let details: MacClippyItemDetails
    let spilledBlobIDs: [Int: String]
}

private struct MacClippyRuntimeDetailsContent {
    let textContent: String?
    let textContentPreview: String?
    let fileURLs: [URL]
    let imageDimensions: CGSize?
}

extension MacClippyRuntime {
    private static let cardPreviewCharacterLimit = 2_000
    private static let detailsOCRCharacterLimit = 16_000

    private static func boundedDisplayText(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let remaining = value.count - limit
        return String(value.prefix(limit))
            + "\n\n— Preview shortened for performance · \(remaining) more characters —"
    }

    func snippets() throws -> [MacClippySnippetEntry] {
        try withStoreLock {
            let snippets = try snippetStore.list()
            snippetLookupSnapshot.replace(with: snippets)
            return snippets.map { MacClippySnippetEntry(snippet: $0) }
        }
    }

    func metadataOnlyHistoryEntry(for meta: ClipboardItemMeta) -> MacClippyHistoryEntry? {
        guard MacClippyDockPageLoadPolicy.canProjectFromMetadata(contentKind: meta.contentKind),
              let contentKind = meta.contentKind else {
            return nil
        }
        let fileURLs = contentKind == .files
            ? MacClippyDockPageLoadPolicy.fileURLs(fromPreview: meta.preview)
            : []
        let preview: String
        if contentKind == .image,
           let ocrText = meta.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ocrText.isEmpty {
            preview = ocrText.count > Self.cardPreviewCharacterLimit
                ? String(ocrText.prefix(Self.cardPreviewCharacterLimit)) + " …"
                : ocrText
        } else if contentKind == .files {
            preview = String(
                MacClippyFilePresentation.displayPreview(fromStoredPreview: meta.preview)
                    .prefix(Self.cardPreviewCharacterLimit)
            )
        } else {
            preview = String(meta.preview.prefix(Self.cardPreviewCharacterLimit))
        }
        let imageDimensions: CGSize?
        if contentKind == .image,
           let size = MacClippyDockPageLoadPolicy.imagePixelSize(fromPreview: meta.preview) {
            imageDimensions = CGSize(width: size.width, height: size.height)
        } else {
            imageDimensions = nil
        }
        return MacClippyHistoryEntry(
            meta: meta,
            contentKind: contentKind,
            preview: preview,
            fileURLs: fileURLs,
            imageDimensions: imageDimensions
        )
    }

    func createSnippet(from recordID: RecordID) throws -> MacClippySnippetEntry {
        try withStoreLock {
            let record = try clipboardStore.body(for: recordID)
            guard let body = MacClippyClipboardText.plainText(from: record) else {
                throw MacClippySnippetCreationError.unsupportedContent
            }

            let name = snippetName(for: body)
            let snippet = try snippetStore.create(name: name, body: body)
            snippetLookupSnapshot.replace(with: try snippetStore.list())
            return MacClippySnippetEntry(snippet: snippet)
        }
    }

    func createSnippet(
        name: String,
        trigger: String?,
        body: String,
        folder: String? = nil
    ) throws -> MacClippySnippetEntry {
        try withStoreLock {
            let input = try validatedSnippetInput(name: name, trigger: trigger, body: body)
            let normalizedName = input.name
            let normalizedTrigger = input.trigger

            let snippet = try snippetStore.create(
                name: normalizedName,
                body: body,
                trigger: normalizedTrigger,
                folder: folder
            )
            let snippets = try snippetStore.list()
            snippetLookupSnapshot.replace(with: snippets)
            return MacClippySnippetEntry(snippet: snippet)
        }
    }

    private func snippetName(for body: String) -> String {
        let firstLine = body.components(separatedBy: .newlines).first ?? body
        let normalized = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Snippet" }
        return String(normalized.prefix(48))
    }

    func normalizedSnippetTrigger(_ trigger: String?) -> String? {
        guard let trigger = trigger?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trigger.isEmpty else { return nil }
        return trigger.hasPrefix(";") ? trigger : ";\(trigger)"
    }

    // Thumbnail callers only need the primary image bytes. Keep this separate
    // from the general preview enum so card rendering does not construct or
    // retain text/file preview values on the image path.
    func imageData(id: RecordID) throws -> Data {
        let (blobID, blobLease) = try withStoreLock { () throws -> (String, MacClippyBlobLease) in
            switch try clipboardStore.body(for: id) {
            case let .image(blobID, _, _), let .encryptedImage(blobID, _, _):
                return (blobID, try blobStore.acquireReadLease(for: [blobID]))
            case .text, .html, .rtf, .files:
                throw MacClippyStoreError.invalidStoredRecord
            }
        }
        defer { blobLease.release() }
        #if DEBUG
            afterImageBlobLeaseAcquiredForTesting?(blobID)
        #endif
        return try readImageBlob(id: blobID, maxBytes: 128 * 1_024 * 1_024)
    }

    func details(id: RecordID) throws -> MacClippyItemDetails {
        let snapshot = try withStoreLock { try makeDetailsSnapshotLocked(id: id) }
        var representations = snapshot.details.representations
        for (index, blobID) in snapshot.spilledBlobIDs {
            let available = try blobStore.containsChecked(id: blobID)
            representations[index] = MacClippyItemRepresentationDetails(
                itemIndex: representations[index].itemIndex,
                uti: representations[index].uti,
                payloadState: representations[index].payloadState,
                byteCount: available ? (try blobStore.byteSizeChecked(id: blobID)) : 0,
                isAvailable: available
            )
        }
        return Self.copyDetails(snapshot.details, representations: representations)
    }

    private func makeDetailsSnapshotLocked(id: RecordID) throws -> MacClippyRuntimeDetailsSnapshot {
        guard let meta = try clipboardStore.metas(for: [id]).first else {
            throw MacClippyStoreError.recordNotFound
        }
        let record = try clipboardStore.body(for: id)
        let representationSnapshot = try detailsRepresentationsLocked(id: id)
        let content = detailsContent(for: record)
        let boardNames = try pinboardStore.list().compactMap { board in
            board.itemIDs.contains(id) ? board.name : nil
        }
        let details = MacClippyItemDetails(
            id: id,
            title: meta.customLabel ?? meta.preview,
            contentKind: record.contentKind,
            sourceAppBundleID: meta.sourceAppBundleID,
            created: meta.created,
            modified: meta.modified,
            frequency: meta.frequency,
            lastAccessed: meta.lastAccessed,
            customLabel: meta.customLabel,
            ocrText: meta.ocrText.map {
                Self.boundedDisplayText($0, limit: Self.detailsOCRCharacterLimit)
            },
            preview: meta.preview,
            textContent: content.textContent,
            textContentPreview: content.textContentPreview,
            fileURLs: content.fileURLs,
            imageDimensions: content.imageDimensions,
            pinboardNames: boardNames,
            representations: representationSnapshot.representations
        )
        return MacClippyRuntimeDetailsSnapshot(
            details: details,
            spilledBlobIDs: representationSnapshot.spilledBlobIDs
        )
    }

    private func detailsRepresentationsLocked(
        id: RecordID
    ) throws -> (representations: [MacClippyItemRepresentationDetails], spilledBlobIDs: [Int: String]) {
        var spilledBlobIDs: [Int: String] = [:]
        let representations = try clipboardStore.representationMetadata(for: id)
            .enumerated()
            .map { index, representation in
            let byteCount: Int
            let isAvailable: Bool
            switch representation.payloadState {
            case .present:
                byteCount = representation.inlineByteCount
                isAvailable = true
            case .spilled:
                guard let blobID = representation.blobID else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                spilledBlobIDs[index] = blobID
                byteCount = 0
                isAvailable = false
            case .unavailable, .oversized:
                byteCount = 0
                isAvailable = false
            }
            return MacClippyItemRepresentationDetails(
                itemIndex: representation.itemIndex,
                uti: representation.uti,
                payloadState: representation.payloadState,
                byteCount: byteCount,
                isAvailable: isAvailable
            )
        }
        return (representations, spilledBlobIDs)
    }

    private func detailsContent(for record: MacClippyClipboardRecord) -> MacClippyRuntimeDetailsContent {
        func boundedText(_ value: String) -> (editable: String?, preview: String) {
            guard value.count <= MacClippyDockPreviewTextPolicy.maxRenderedCharacters else {
                return (nil, MacClippyDockPreviewTextPolicy.displayText(for: value))
            }
            return (value, value)
        }

        switch record {
        case let .text(value), let .html(value):
            let bounded = boundedText(value)
            return MacClippyRuntimeDetailsContent(
                textContent: bounded.editable,
                textContentPreview: bounded.preview,
                fileURLs: [],
                imageDimensions: nil
            )
        case let .rtf(data):
            let value = String(data: data, encoding: .utf8)
                ?? MacClippyClipboardText.plainText(from: .rtf(data))
                ?? ""
            let bounded = boundedText(value)
            return MacClippyRuntimeDetailsContent(
                textContent: bounded.editable,
                textContentPreview: bounded.preview,
                fileURLs: [],
                imageDimensions: nil
            )
        case let .files(urls):
            return MacClippyRuntimeDetailsContent(
                textContent: nil,
                textContentPreview: nil,
                fileURLs: urls,
                imageDimensions: nil
            )
        case let .image(_, width, height), let .encryptedImage(_, width, height):
            return MacClippyRuntimeDetailsContent(
                textContent: nil,
                textContentPreview: nil,
                fileURLs: [],
                imageDimensions: CGSize(width: width, height: height)
            )
        }
    }

    private static func copyDetails(
        _ details: MacClippyItemDetails,
        representations: [MacClippyItemRepresentationDetails]
    ) -> MacClippyItemDetails {
        MacClippyItemDetails(
            id: details.id,
            title: details.title,
            contentKind: details.contentKind,
            sourceAppBundleID: details.sourceAppBundleID,
            created: details.created,
            modified: details.modified,
            frequency: details.frequency,
            lastAccessed: details.lastAccessed,
            customLabel: details.customLabel,
            ocrText: details.ocrText,
            preview: details.preview,
            textContent: details.textContent,
            textContentPreview: details.textContentPreview,
            fileURLs: details.fileURLs,
            imageDimensions: details.imageDimensions,
            pinboardNames: details.pinboardNames,
            representations: representations
        )
    }
}
