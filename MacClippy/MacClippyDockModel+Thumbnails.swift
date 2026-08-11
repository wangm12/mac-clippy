import AppKit
import CoreGraphics
import Foundation

import MacClippyCore
import MacClippyPlatform

private func macClippyLoadThumbnail(
    runtime: MacClippyRuntime,
    id: RecordID,
    maxPixelSize: Int
) -> CGImage? {
    do {
        let data = try runtime.imageData(id: id)
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
    // Card thumbnails use their own non-cancelled path. The Space Preview
    // loader is latest-wins by design, but using it for every visible image
    // card would make thumbnails cancel one another. Downsample before the
    // result reaches SwiftUI and cache by record ID.
    func loadImageThumbnail(
        for id: RecordID,
        maxPixelSize: Int = 480,
        completion: @escaping @MainActor @Sendable (CGImage?) -> Void
    ) {
        let requestKey = ThumbnailRequestKey(id: id, maxPixelSize: max(1, maxPixelSize))
        if let cached = thumbnailCache.object(forKey: requestKey.cacheKey) {
            completion(cached.image)
            return
        }
        if thumbnailCompletions[requestKey] != nil {
            thumbnailCompletions[requestKey, default: []].append(completion)
            return
        }
        thumbnailCompletions[requestKey] = [completion]

        let runtimeReference = runtime
        thumbnailQueue.addOperation { [weak self, runtimeReference] in
            let thumbnailImage = macClippyLoadThumbnail(
                runtime: runtimeReference,
                id: id,
                maxPixelSize: requestKey.maxPixelSize
            )

            DispatchQueue.main.async { [weak self, thumbnailImage] in
                guard let self else { return }
                if let thumbnailImage {
                    self.thumbnailCache.setObject(
                        ThumbnailCacheEntry(image: thumbnailImage),
                        forKey: requestKey.cacheKey,
                        cost: thumbnailImage.width * thumbnailImage.height * 4
                    )
                }
                let completions = self.thumbnailCompletions.removeValue(forKey: requestKey) ?? []
                completions.forEach { $0(thumbnailImage) }
            }
        }
    }
}
