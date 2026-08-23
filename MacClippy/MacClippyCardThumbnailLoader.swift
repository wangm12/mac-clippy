import AppKit
import Foundation

import MacClippyCore
import MacClippyPlatform

final class MacClippyCardThumbnailWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let releaseHandler: () -> Void

    init(releaseHandler: @escaping () -> Void) {
        self.releaseHandler = releaseHandler
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        releaseHandler()
    }
}

private final class MacClippyThumbnailImageResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var image: CGImage?
    private var continuation: CheckedContinuation<CGImage?, Never>?

    func resume(_ value: CGImage?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        image = value
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    var valueToAwait: CGImage? {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if completed {
                    let image = self.image
                    lock.unlock()
                    continuation.resume(returning: image)
                    return
                }
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// Loads card thumbnails with file-icon-style last-waiter cancellation.
/// ImageIO cannot abort mid-decode; cancellation is checked before `imageData`
/// and before downsample. A finished decode is still written to cache.
final class MacClippyCardThumbnailLoader: @unchecked Sendable {
    typealias LoadImage = @Sendable (RecordID, Int, @Sendable () -> Bool) -> CGImage?

    final class CacheEntry: NSObject {
        let image: CGImage

        init(image: CGImage) {
            self.image = image
        }
    }

    struct RequestKey: Hashable {
        let id: RecordID
        let maxPixelSize: Int

        var cacheKey: NSString {
            "\(id.rawValue)#\(maxPixelSize)" as NSString
        }
    }

    private final class Flight: @unchecked Sendable {
        let accounting = MacClippyFileIconWaiterAccounting()
        let operation = BlockOperation()
        var waiters: [UUID: @Sendable (CGImage?) -> Void] = [:]
    }

    let cache: NSCache<NSString, CacheEntry>
    let queue: OperationQueue
    let loadImage: LoadImage
    var afterDecode: @Sendable () -> Void = {}
    var onFinish: (@Sendable (CGImage?) -> Void)?

    private let lock = NSLock()
    private var flights: [RequestKey: Flight] = [:]

    init(
        cache: NSCache<NSString, CacheEntry>,
        queue: OperationQueue,
        loadImage: @escaping LoadImage
    ) {
        self.cache = cache
        self.queue = queue
        self.loadImage = loadImage
    }

    func cachedImage(id: RecordID, maxPixelSize: Int) -> CGImage? {
        cache.object(forKey: RequestKey(id: id, maxPixelSize: max(1, maxPixelSize)).cacheKey)?.image
    }

    func resetForSessionEnd() {
        queue.cancelAllOperations()
        cache.removeAllObjects()
    }

    func image(for id: RecordID, maxPixelSize: Int = 480) async -> CGImage? {
        let box = MacClippyThumbnailImageResumeBox()
        let waiter = load(id: id, maxPixelSize: maxPixelSize) { image in
            box.resume(image)
        }
        return await withTaskCancellationHandler {
            await box.valueToAwait
        } onCancel: {
            waiter.release()
            box.resume(nil)
        }
    }

    func load(
        id: RecordID,
        maxPixelSize: Int,
        completion: @escaping @Sendable (CGImage?) -> Void
    ) -> MacClippyCardThumbnailWaiter {
        let key = RequestKey(id: id, maxPixelSize: max(1, maxPixelSize))
        if let cached = cache.object(forKey: key.cacheKey) {
            completion(cached.image)
            return MacClippyCardThumbnailWaiter(releaseHandler: {})
        }

        lock.lock()
        if let cached = cache.object(forKey: key.cacheKey) {
            lock.unlock()
            completion(cached.image)
            return MacClippyCardThumbnailWaiter(releaseHandler: {})
        }

        let waiterID = UUID()
        if let existing = flights[key], !existing.operation.isCancelled {
            existing.accounting.addWaiter()
            existing.waiters[waiterID] = completion
            lock.unlock()
            return MacClippyCardThumbnailWaiter { [weak self] in
                self?.releaseWaiter(key, waiterID: waiterID)
            }
        }
        if flights[key]?.operation.isCancelled == true {
            flights.removeValue(forKey: key)
        }

        let flight = Flight()
        flight.accounting.addWaiter()
        flight.waiters[waiterID] = completion
        flights[key] = flight
        let operation = flight.operation
        let loadImage = self.loadImage
        let afterDecode = self.afterDecode
        operation.addExecutionBlock { [weak self] in
            guard let self else { return }
            guard !operation.isCancelled else {
                self.finish(key, flight: flight, image: nil)
                return
            }
            let isCancelled: @Sendable () -> Bool = {
                operation.isCancelled
            }
            let image = loadImage(id, key.maxPixelSize, isCancelled)
            afterDecode()
            self.finish(key, flight: flight, image: image)
        }
        lock.unlock()
        queue.addOperation(operation)

        return MacClippyCardThumbnailWaiter { [weak self] in
            self?.releaseWaiter(key, waiterID: waiterID)
        }
    }

    private func releaseWaiter(_ key: RequestKey, waiterID: UUID) {
        lock.lock()
        guard let flight = flights[key] else {
            lock.unlock()
            return
        }
        flight.waiters.removeValue(forKey: waiterID)
        if flight.accounting.releaseWaiter() {
            let operation = flight.operation
            operation.cancel()
            let shouldFinishNow = !operation.isExecuting && !operation.isFinished
            lock.unlock()
            if shouldFinishNow {
                finish(key, flight: flight, image: nil)
            }
            return
        }
        lock.unlock()
    }

    private func finish(_ key: RequestKey, flight: Flight, image: CGImage?) {
        lock.lock()
        guard flights[key] === flight else {
            lock.unlock()
            return
        }
        flights.removeValue(forKey: key)
        flight.accounting.markFinished()
        let waiters = flight.waiters
        flight.waiters = [:]
        if let image {
            cache.setObject(
                CacheEntry(image: image),
                forKey: key.cacheKey,
                cost: image.width * image.height * 4
            )
        }
        let onFinish = self.onFinish
        lock.unlock()

        if Thread.isMainThread {
            waiters.values.forEach { $0(image) }
            onFinish?(image)
        } else {
            DispatchQueue.main.async {
                waiters.values.forEach { $0(image) }
                onFinish?(image)
            }
        }
    }
}
