import AppKit
import CoreGraphics
import Foundation

import MacClippyCore
import MacClippyPlatform

private final class MacClippyThumbnailRuntimeHandle: @unchecked Sendable {
    let runtime: MacClippyRuntime

    init(_ runtime: MacClippyRuntime) {
        self.runtime = runtime
    }
}

private func macClippyLoadThumbnail(
    runtime: MacClippyRuntime,
    id: RecordID,
    maxPixelSize: Int,
    isCancelled: () -> Bool
) -> CGImage? {
    do {
        guard !isCancelled() else { return nil }
        let data = try runtime.imageData(id: id)
        guard !isCancelled() else { return nil }
        guard let downsampled = MacClippyThumbnailDownsampler.image(
            data,
            maxPixelSize: maxPixelSize
        ) else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        return downsampled
    } catch let error as MacClippyStoreError {
        if case .recordNotFound = error {
            // The card can disappear between the history snapshot and
            // thumbnail work. This is a normal stale-snapshot outcome.
        } else {
            MacClippyLog.record(
                category: .blob,
                code: .blobIntegrityFailed,
                operation: "thumbnail_load",
                recoveryAction: "run_storage_reconciliation",
                impact: "thumbnail_unavailable"
            )
        }
        return nil
    } catch {
        MacClippyLog.record(
            category: .blob,
            code: .blobIntegrityFailed,
            operation: "thumbnail_load",
            recoveryAction: "run_storage_reconciliation",
            impact: "thumbnail_unavailable"
        )
        return nil
    }
}

extension MacClippyDockModel {
    static func makeThumbnailLoader(runtime: MacClippyRuntime) -> MacClippyCardThumbnailLoader {
        let cache = NSCache<NSString, MacClippyCardThumbnailLoader.CacheEntry>()
        cache.countLimit = 48
        cache.totalCostLimit = 64 * 1024 * 1024
        let queue = OperationQueue()
        queue.name = "com.macallyouneed.macclippy.thumbnail"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        let runtimeHandle = MacClippyThumbnailRuntimeHandle(runtime)
        return MacClippyCardThumbnailLoader(
            cache: cache,
            queue: queue,
            loadImage: { id, maxPixelSize, isCancelled in
                macClippyLoadThumbnail(
                    runtime: runtimeHandle.runtime,
                    id: id,
                    maxPixelSize: maxPixelSize,
                    isCancelled: isCancelled
                )
            },
            diskCache: runtime.thumbnailDiskCache
        )
    }

    func loadImageThumbnail(
        for id: RecordID,
        maxPixelSize: Int = 480
    ) async -> CGImage? {
        await thumbnailLoader.image(for: id, maxPixelSize: maxPixelSize)
    }
}
