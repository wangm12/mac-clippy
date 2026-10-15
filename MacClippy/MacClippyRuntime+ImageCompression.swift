import Foundation
import UniformTypeIdentifiers

import MacClippyCore

struct MacClippyImageCompressionSnapshot {
    let meta: ClipboardItemMeta
    let body: ClipboardRecord
    let blobID: String
    let width: Int
    let height: Int
    let representations: [MacClippyClipboardRepresentation]
    let imageItemIndex: Int
    let encrypted: Bool
    let sourceLease: MacClippyBlobLease
}

struct MacClippyPreparedImageCompression {
    let blobID: String
    let data: Data
    let width: Int
    let height: Int
    let contentHash: String
    let representations: [MacClippyClipboardRepresentation]
}

private struct MacClippyImageCompressionSource {
    let data: Data
    let byteCount: Int
    let hashRepresentations: [MacClippyCaptureDedupRepresentation]
}

struct MacClippyImageCompressionLifecycle {
    let generation: UInt64
    let token: MacClippyRuntimeLifecycleToken?
}

extension MacClippyRuntime {
    private static let imageCompressionPageSize = 64
    private static let imageCompressionLimit = 64

    func compressOldImages(now: Date = Date()) throws -> MacClippyImageCompressReport {
        let coordinator = MacClippyMaintenanceIOCoordinator.shared
        guard let operation = coordinator.beginOperation(at: paths.rootURL, kind: .compression) else {
            return MacClippyImageCompressReport()
        }
        defer { operation.finish() }

        let lifecycle = withLifecycleStateLock {
            let token = running ? MacClippyRuntimeLifecycleToken(generation: lifecycleGeneration) : nil
            return MacClippyImageCompressionLifecycle(generation: lifecycleGeneration, token: token)
        }
        var report = MacClippyImageCompressReport()
        var cursor: MacClippyClipboardHistoryCursor?
        while report.compressedCount < Self.imageCompressionLimit {
            try checkCompressionCancellation(operation, lifecycle: lifecycle)
            let page = try withStoreLock {
                try clipboardStore.listOldest(
                    limit: Self.imageCompressionPageSize,
                    after: cursor,
                    contentKind: .image
                )
            }
            guard !page.isEmpty else { break }

            for meta in page {
                try checkCompressionCancellation(operation, lifecycle: lifecycle)
                if let savedBytes = try compressImage(
                    for: meta,
                    now: now,
                    operation: operation,
                    lifecycle: lifecycle
                ) {
                    report.compressedCount += 1
                    report.bytesSaved += savedBytes
                }
                guard report.compressedCount < Self.imageCompressionLimit else { break }
            }
            guard page.count == Self.imageCompressionPageSize, let last = page.last else { break }
            cursor = MacClippyClipboardHistoryCursor(
                modified: last.modified,
                lamport: last.lamport,
                id: last.id
            )
        }
        return report
    }

    private func compressImage(
        for listedMeta: ClipboardItemMeta,
        now: Date,
        operation: MacClippyMaintenanceIOCoordinator.Operation,
        lifecycle: MacClippyImageCompressionLifecycle
    ) throws -> Int64? {
        guard let snapshot = try imageCompressionSnapshot(for: listedMeta, operation: operation) else {
            return nil
        }
        defer { snapshot.sourceLease.release() }
        guard let source = try readCompressionSource(snapshot, now: now, operation: operation),
              let prepared = try prepareCompressedImage(
                  source,
                  snapshot: snapshot,
                  operation: operation,
                  lifecycle: lifecycle
              ) else {
            return nil
        }
        let retiredBlobIDs = Set([snapshot.blobID] + snapshot.representations.compactMap(\.blobID))
        let committed = try commitCompression(
            prepared,
            snapshot: snapshot,
            retiredBlobIDs: retiredBlobIDs,
            operation: operation,
            lifecycle: lifecycle
        )
        guard committed else {
            removeUnreferencedCompressionBlob(prepared.blobID, operation: operation)
            return nil
        }
        guard let thumbnailIO = operation.beginCriticalIO() else {
            return Int64(source.byteCount - prepared.data.count)
        }
        thumbnailDiskCache.remove(id: snapshot.meta.id)
        thumbnailIO.release()
        return Int64(source.byteCount - prepared.data.count)
    }

    private func readCompressionSource(
        _ snapshot: MacClippyImageCompressionSnapshot,
        now: Date,
        operation: MacClippyMaintenanceIOCoordinator.Operation
    ) throws -> MacClippyImageCompressionSource? {
        guard let sourceIO = operation.beginCriticalIO() else { throw CancellationError() }
        defer { sourceIO.release() }
        defer { snapshot.sourceLease.release() }
        let byteCount = try blobStore.byteSizeChecked(id: snapshot.blobID)
        guard MacClippyStorageDashboardPolicy.shouldCompress(
            isProtected: false,
            modified: snapshot.meta.modified,
            now: now,
            byteCount: byteCount,
            longestEdge: max(snapshot.width, snapshot.height)
        ) else {
            return nil
        }
        let data = try blobStore.read(id: snapshot.blobID, maxBytes: 128 * 1_024 * 1_024)
        let hashRepresentations = try compressionHashRepresentations(snapshot, primaryData: data)
        sourceIO.release()
        snapshot.sourceLease.release()
        #if DEBUG
            MacClippyMaintenanceIOTestHooks.afterImageRead()
        #endif
        return MacClippyImageCompressionSource(
            data: data,
            byteCount: byteCount,
            hashRepresentations: hashRepresentations
        )
    }

    private func compressionHashRepresentations(
        _ snapshot: MacClippyImageCompressionSnapshot,
        primaryData: Data
    ) throws -> [MacClippyCaptureDedupRepresentation] {
        try snapshot.representations.map { representation in
            let bytes: Data?
            let state: String
            switch representation.payloadState {
            case .present:
                bytes = representation.payloadBytes
                state = MacClippyClipboardRepresentationPayloadState.present.rawValue
            case .spilled:
                guard let spilledID = representation.blobID else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                bytes = spilledID == snapshot.blobID
                    ? primaryData
                    : try blobStore.read(
                        id: spilledID,
                        maxBytes: MacClippyPasteboardInputLimits.default.maxRepresentationBytes
                    )
                state = MacClippyClipboardRepresentationPayloadState.present.rawValue
            case .unavailable:
                bytes = nil
                state = MacClippyClipboardRepresentationPayloadState.unavailable.rawValue
            case .oversized:
                bytes = nil
                state = MacClippyClipboardRepresentationPayloadState.oversized.rawValue
            }
            return MacClippyCaptureDedupRepresentation(
                itemIndex: representation.itemIndex,
                uti: representation.uti,
                payloadState: state,
                payloadBytes: bytes
            )
        }
    }

    private func prepareCompressedImage(
        _ source: MacClippyImageCompressionSource,
        snapshot: MacClippyImageCompressionSnapshot,
        operation: MacClippyMaintenanceIOCoordinator.Operation,
        lifecycle: MacClippyImageCompressionLifecycle
    ) throws -> MacClippyPreparedImageCompression? {
        try checkCompressionCancellation(operation, lifecycle: lifecycle)
        guard let compressed = MacClippyThumbnailDownsampler.compressedJPEG(
            from: source.data,
            maxPixelSize: MacClippyStorageDashboardPolicy.compressTargetMaxPixelSize
        ), MacClippyStorageDashboardPolicy.isWorthReplacing(
            originalBytes: source.byteCount,
            compressedBytes: compressed.data.count
        ) else {
            return nil
        }
        try checkCompressionCancellation(operation, lifecycle: lifecycle)

        let blobID = RecordID.generate().rawValue
        let newRepresentations = try compressedRepresentations(
            replacing: snapshot.representations,
            itemIndex: snapshot.imageItemIndex,
            blobID: blobID
        )
        let replacementHashRepresentations = compressedHashRepresentations(
            replacing: source.hashRepresentations,
            itemIndex: snapshot.imageItemIndex,
            data: compressed.data
        )
        let contentHash = MacClippyCaptureDedupPolicy.contentHash(
            primary: .image(compressed.data, width: compressed.width, height: compressed.height),
            representations: replacementHashRepresentations
        )
        try checkCompressionCancellation(operation, lifecycle: lifecycle)
        guard let outputIO = operation.beginCriticalIO() else { throw CancellationError() }
        do {
            try blobStore.write(compressed.data, id: blobID)
            outputIO.release()
        } catch {
            outputIO.release()
            throw error
        }
        return MacClippyPreparedImageCompression(
            blobID: blobID,
            data: compressed.data,
            width: compressed.width,
            height: compressed.height,
            contentHash: contentHash,
            representations: newRepresentations
        )
    }

    private func compressedRepresentations(
        replacing representations: [MacClippyClipboardRepresentation],
        itemIndex: Int,
        blobID: String
    ) throws -> [MacClippyClipboardRepresentation] {
        let replacedIndices = representations.indices.filter { index in
            let representation = representations[index]
            return representation.itemIndex == itemIndex && isImageRepresentation(representation.uti)
        }
        var result: [MacClippyClipboardRepresentation] = []
        result.reserveCapacity(representations.count + 1)
        let insertionIndex = replacedIndices.first
        for (index, representation) in representations.enumerated() {
            if index == insertionIndex {
                result.append(MacClippyClipboardRepresentation(
                    itemIndex: itemIndex,
                    uti: "public.jpeg",
                    payloadBytes: nil,
                    blobID: blobID,
                    payloadState: .spilled
                ))
            }
            guard !replacedIndices.contains(index) else { continue }
            result.append(representation)
        }
        if insertionIndex == nil {
            result.append(MacClippyClipboardRepresentation(
                itemIndex: itemIndex,
                uti: "public.jpeg",
                payloadBytes: nil,
                blobID: blobID,
                payloadState: .spilled
            ))
        }
        let limits = MacClippyPasteboardInputLimits.default
        guard result.count <= limits.maxRepresentationsPerRecord,
              result.filter({ $0.itemIndex == itemIndex }).count <= limits.maxRepresentationsPerItem else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        return result
    }

    private func compressedHashRepresentations(
        replacing representations: [MacClippyCaptureDedupRepresentation],
        itemIndex: Int,
        data: Data
    ) -> [MacClippyCaptureDedupRepresentation] {
        let replacedIndices = representations.indices.filter { index in
            let representation = representations[index]
            return representation.itemIndex == itemIndex && isImageRepresentation(representation.uti)
        }
        let insertionIndex = replacedIndices.first
        var result: [MacClippyCaptureDedupRepresentation] = []
        result.reserveCapacity(representations.count + 1)
        for (index, representation) in representations.enumerated() {
            if index == insertionIndex {
                result.append(MacClippyCaptureDedupRepresentation(
                    itemIndex: itemIndex,
                    uti: "public.jpeg",
                    payloadState: MacClippyClipboardRepresentationPayloadState.present.rawValue,
                    payloadBytes: data
                ))
            }
            guard !replacedIndices.contains(index) else { continue }
            result.append(representation)
        }
        if insertionIndex == nil {
            result.append(MacClippyCaptureDedupRepresentation(
                itemIndex: itemIndex,
                uti: "public.jpeg",
                payloadState: MacClippyClipboardRepresentationPayloadState.present.rawValue,
                payloadBytes: data
            ))
        }
        return result
    }

}
