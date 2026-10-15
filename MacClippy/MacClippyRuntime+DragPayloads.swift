import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import MacClippyCore
import MacClippyPlatform

private struct MacClippyDragPayloadPreparation {
    let selectedContent: MacClippyPasteboardContent
    let fallbackRecord: ClipboardRecord?
    let fallbackImageData: Data?
    let fallbackRepresentations: Set<MacClippyCardDragRepresentation>
}

extension MacClippyRuntime {
    func dragPayload(
        id: RecordID,
        representation: MacClippyCardDragRepresentation
    ) throws -> MacClippyCardDragPayload {
        guard let payload = try dragPayloads(id: id, representations: [representation])[representation] else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        return payload
    }

    /// Builds all requested drag payloads from one authenticated snapshot.
    /// NSItemProvider may ask for several representations of the same item;
    /// rereading and decrypting the complete record for each request adds drag
    /// latency without changing the result.
    func dragPayloads(
        id: RecordID,
        representations: [MacClippyCardDragRepresentation]
    ) throws -> [MacClippyCardDragRepresentation: MacClippyCardDragPayload] {
        var payloads: [MacClippyCardDragRepresentation: MacClippyCardDragPayload] = [:]
        let requested = Set(representations)
        if requested.contains(.recordID) {
            payloads[.recordID] = MacClippyCardDragPayload(
                typeIdentifier: MacClippyCardDragPolicy.recordTypeIdentifier,
                data: Data(id.rawValue.utf8)
            )
        }

        var seenRepresentations = Set<MacClippyCardDragRepresentation>()
        let contentRepresentations = representations.filter {
            $0 != .recordID && seenRepresentations.insert($0).inserted
        }
        guard !contentRepresentations.isEmpty else { return payloads }
        let requestedUTIs = Set(contentRepresentations.flatMap(Self.dragRepresentationUTIs))
        let includesImage = contentRepresentations.contains(.image)
        let prepared: MacClippyDragPayloadPreparation = try withStoreLock {
            try prepareDragPayloadsLocked(
                id: id,
                requestedUTIs: requestedUTIs,
                includesImage: includesImage,
                contentRepresentations: contentRepresentations
            )
        }

        payloads.merge(try materializeDragPayloads(
            id: id, representations: contentRepresentations, prepared: prepared
        )) { _, content in content }
        return payloads
    }

    private func materializeDragPayloads(
        id: RecordID,
        representations: [MacClippyCardDragRepresentation],
        prepared: MacClippyDragPayloadPreparation
    ) throws -> [MacClippyCardDragRepresentation: MacClippyCardDragPayload] {
        var payloads: [MacClippyCardDragRepresentation: MacClippyCardDragPayload] = [:]
        var fallbackContent: MacClippyPasteboardContent?
        var didResolveFallbackContent = false
        for representation in representations {
            var payload = try MacClippyCardDragExportPolicy.payloadThrowing(
                for: representation,
                recordID: id,
                content: prepared.selectedContent
            )
            if payload == nil, prepared.fallbackRepresentations.contains(representation) {
                if !didResolveFallbackContent {
                    if let fallbackImageData = prepared.fallbackImageData {
                        fallbackContent = .image(fallbackImageData)
                    } else if let fallbackRecord = prepared.fallbackRecord {
                        fallbackContent = try pasteboardContent(for: fallbackRecord, plain: false)
                    }
                    didResolveFallbackContent = true
                }
                if let fallbackContent {
                    payload = try MacClippyCardDragExportPolicy.payloadThrowing(
                        for: representation,
                        recordID: id,
                        content: fallbackContent
                    )
                }
            }
            if let payload {
                payloads[representation] = payload
            }
        }
        return payloads
    }

    private func prepareDragPayloadsLocked(
        id: RecordID,
        requestedUTIs: Set<String>,
        includesImage: Bool,
        contentRepresentations: [MacClippyCardDragRepresentation]
    ) throws -> MacClippyDragPayloadPreparation {
        let snapshot: MacClippyClipboardPlaybackSnapshot
        if includesImage {
            snapshot = try clipboardStore.playbackSnapshot(
                for: id,
                matchingRepresentationUTIs: requestedUTIs,
                matchingAdditionalRepresentationUTIs: { uti in
                    UTType(uti)?.conforms(to: .image) == true
                }
            )
        } else {
            snapshot = try clipboardStore.playbackSnapshot(
                for: id,
                matchingRepresentationUTIs: requestedUTIs
            )
        }

        let selectedContent = try dragPasteboardContent(from: snapshot.representations)
        let fallbackRepresentations = Set(contentRepresentations.filter {
            !selectedContentHasCandidate(for: $0, in: selectedContent)
        })
        var fallbackRecord: ClipboardRecord?
        var fallbackImageData: Data?
        if !fallbackRepresentations.isEmpty {
            switch snapshot.record {
            case let .image(blobID, _, _), let .encryptedImage(blobID, _, _):
                if fallbackRepresentations.contains(.image) {
                    // Read the primary blob under storeLock so deletion
                    // cannot race the read lease acquisition.
                    fallbackImageData = try blobStore.read(id: blobID)
                }
            default:
                fallbackRecord = snapshot.record
            }
        }
        return MacClippyDragPayloadPreparation(
            selectedContent: selectedContent,
            fallbackRecord: fallbackRecord,
            fallbackImageData: fallbackImageData,
            fallbackRepresentations: fallbackRepresentations
        )
    }

    private func selectedContentHasCandidate(
        for representation: MacClippyCardDragRepresentation,
        in content: MacClippyPasteboardContent
    ) -> Bool {
        guard case let .items(items) = content else { return false }
        switch representation {
        case .recordID:
            return true
        case .plainText:
            let utis = Set(["public.utf8-plain-text", "public.html", "public.rtf"])
            return items.contains { item in
                item.types.contains { utis.contains($0) && item.data(forType: $0) != nil }
            }
        case .rtf:
            return items.contains { $0.data(forType: "public.rtf") != nil }
        case .html:
            return items.contains { $0.data(forType: "public.html") != nil }
        case .image:
            return items.contains { item in
                item.types.contains {
                    UTType($0)?.conforms(to: .image) == true && item.data(forType: $0) != nil
                }
            }
        case .fileURL:
            return items.contains { $0.data(forType: "public.file-url") != nil }
        }
    }

    private static func dragRepresentationUTIs(
        _ representation: MacClippyCardDragRepresentation
    ) -> [String] {
        switch representation {
        case .recordID:
            return []
        case .plainText:
            return ["public.utf8-plain-text", "public.html", "public.rtf"]
        case .rtf:
            return ["public.rtf"]
        case .html:
            return ["public.html"]
        case .image:
            return ["public.png", "public.jpeg", "public.tiff"]
        case .fileURL:
            return ["public.file-url"]
        }
    }

    private func dragPasteboardContent(
        from representations: [MacClippyClipboardRepresentation]
    ) throws -> MacClippyPasteboardContent {
        struct ItemBuilder {
            var types: [String] = []
            var representations: [String: Data] = [:]
        }

        var builders: [Int: ItemBuilder] = [:]
        for representation in representations {
            // A missing or unreadable blob for one requested UTI should not
            // prevent other requested text representations from being exported.
            // Image data is the drag result itself, so preserve its read error
            // for the provider instead of silently falling back to the primary.
            let bytes: Data?
            do {
                bytes = try dragPasteboardBytes(for: representation)
            } catch {
                if UTType(representation.uti)?.conforms(to: .image) == true {
                    throw error
                }
                continue
            }
            guard let bytes else { continue }
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
        return .items(items)
    }

    private func dragPasteboardBytes(
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
