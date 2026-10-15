import CoreGraphics
import Foundation

private final class MacClippyFileThumbnailCache: @unchecked Sendable {
    private let storage = NSCache<NSString, CGImage>()

    init() {
        storage.countLimit = 48
        storage.totalCostLimit = 32 * 1_024 * 1_024
    }

    func object(for key: String) -> CGImage? {
        storage.object(forKey: key as NSString)
    }

    func setObject(_ image: CGImage, for key: String) {
        let cost = max(1, image.width * image.height * 4)
        storage.setObject(image, forKey: key as NSString, cost: cost)
    }

    func removeAllObjects() {
        storage.removeAllObjects()
    }
}

final class MacClippyFileThumbnailWaiter: @unchecked Sendable {
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

/// A small, shared scheduler keeps both running decodes and queued identities
/// bounded. Running ImageIO calls retain their worker slot until they return,
/// even after the last waiter cancels.
final class MacClippyFileThumbnailService: @unchecked Sendable {
    typealias ImageIODecoder = @Sendable (URL, CGSize, @Sendable () -> Bool) -> CGImage?
    typealias WorkspaceIconRenderer = @MainActor @Sendable (URL, CGSize, @Sendable () -> Bool) -> CGImage?

    private enum FlightState {
        case pending
        case running
    }

    private final class Flight: @unchecked Sendable {
        let id = UUID()
        let key: String
        let url: URL
        let pointSize: CGSize
        let session: UInt64
        var state = FlightState.pending
        var isCancelled = false
        var waiters: [UUID: @Sendable (CGImage?) -> Void] = [:]

        init(key: String, url: URL, pointSize: CGSize, session: UInt64) {
            self.key = key
            self.url = url
            self.pointSize = pointSize
            self.session = session
        }
    }

    private let cache = MacClippyFileThumbnailCache()
    private let lock = NSLock()
    private let maximumConcurrentWorkers: Int
    private let maximumPendingFlights: Int
    private let imageIODecoder: ImageIODecoder
    private let workspaceIconRenderer: WorkspaceIconRenderer
    private var session: UInt64 = 0
    private var activeWorkerCount = 0
    private var flights: [String: Flight] = [:]
    private var pendingFlights: [Flight] = []

    init(
        maximumConcurrentWorkers: Int = 2,
        maximumPendingFlights: Int = 64,
        imageIODecoder: @escaping ImageIODecoder,
        workspaceIconRenderer: @escaping WorkspaceIconRenderer
    ) {
        self.maximumConcurrentWorkers = min(2, max(1, maximumConcurrentWorkers))
        self.maximumPendingFlights = max(0, maximumPendingFlights)
        self.imageIODecoder = imageIODecoder
        self.workspaceIconRenderer = workspaceIconRenderer
    }

    func cachedImage(forKey key: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(for: key)
    }

    func resetForSessionEnd() {
        lock.lock()
        session &+= 1
        let cancelledFlights = Array(flights.values)
        flights.removeAll()
        pendingFlights.removeAll()
        cache.removeAllObjects()
        let completions = cancelledFlights.flatMap { flight -> [@Sendable (CGImage?) -> Void] in
            flight.isCancelled = true
            let waiters = Array(flight.waiters.values)
            flight.waiters.removeAll()
            return waiters
        }
        lock.unlock()
        completions.forEach { deliver(nil, to: $0) }
    }

    func image(for url: URL, pointSize: CGSize) async -> CGImage? {
        let box = MacClippyFileThumbnailCompletionBox()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                box.cancel()
                return nil
            }
            let waiter = load(for: url, pointSize: pointSize) { image in
                box.complete(image)
            }
            box.install(waiter)
            let image = await box.value
            return Task.isCancelled ? nil : image
        } onCancel: {
            box.cancel()
        }
    }

    func load(
        for url: URL,
        pointSize: CGSize,
        completion: @escaping @Sendable (CGImage?) -> Void
    ) -> MacClippyFileThumbnailWaiter {
        let key = MacClippyFileThumbnailLoader.cacheKey(url: url, pointSize: pointSize)
        let waiterID = UUID()
        var flightToRun: Flight?
        var joinedFlightID: UUID?
        var completedImage: CGImage?
        var completionSession: UInt64?
        var shouldCompleteImmediately = false

        lock.lock()
        if let cached = cache.object(for: key) {
            completedImage = cached
            completionSession = session
            shouldCompleteImmediately = true
        } else if let existing = flights[key], !existing.isCancelled {
            existing.waiters[waiterID] = completion
            joinedFlightID = existing.id
            completionSession = existing.session
        } else {
            if flights[key]?.isCancelled == true {
                flights.removeValue(forKey: key)
            }
            let flight = Flight(key: key, url: url, pointSize: pointSize, session: session)
            flight.waiters[waiterID] = completion
            flights[key] = flight
            joinedFlightID = flight.id
            completionSession = flight.session
            if activeWorkerCount < maximumConcurrentWorkers {
                flight.state = .running
                activeWorkerCount += 1
                flightToRun = flight
            } else if pendingFlights.count < maximumPendingFlights {
                pendingFlights.append(flight)
            } else {
                flights.removeValue(forKey: key)
                joinedFlightID = nil
                completionSession = nil
                shouldCompleteImmediately = true
            }
        }
        lock.unlock()

        if shouldCompleteImmediately {
            deliver(completedImage, to: completion, session: completionSession)
        }
        if let flightToRun {
            start(flightToRun)
        }

        return MacClippyFileThumbnailWaiter { [weak self] in
            self?.releaseWaiter(key: key, flightID: joinedFlightID, waiterID: waiterID)
        }
    }

    private func releaseWaiter(key: String, flightID: UUID?, waiterID: UUID) {
        guard let flightID else { return }
        lock.lock()
        guard let flight = flights[key], flight.id == flightID else {
            lock.unlock()
            return
        }
        flight.waiters.removeValue(forKey: waiterID)
        guard flight.waiters.isEmpty else {
            lock.unlock()
            return
        }

        flight.isCancelled = true
        flights.removeValue(forKey: key)
        if flight.state == .pending {
            pendingFlights.removeAll { $0 === flight }
        }
        lock.unlock()
    }

    private func start(_ flight: Flight) {
        _ = Task.detached(priority: .utility) { [self] in
            let image = await render(flight)
            finish(flight, image: image)
        }
    }

    private func render(_ flight: Flight) async -> CGImage? {
        let isCancelled: @Sendable () -> Bool = { [weak self, weak flight] in
            guard let self, let flight else { return true }
            return self.flightIsCancelled(flight)
        }
        guard !isCancelled() else { return nil }
        let image: CGImage?
        if MacClippyFileThumbnailPolicy.usesImageIO(for: flight.url) {
            image = imageIODecoder(flight.url, flight.pointSize, isCancelled)
        } else {
            image = await workspaceIconRenderer(flight.url, flight.pointSize, isCancelled)
        }
        return isCancelled() ? nil : image
    }

    private func flightIsCancelled(_ flight: Flight) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flight.isCancelled || flight.session != session || flight.waiters.isEmpty
            || flights[flight.key] !== flight
    }

    private func finish(_ flight: Flight, image: CGImage?) {
        lock.lock()
        var completions: [@Sendable (CGImage?) -> Void] = []
        var resultImage: CGImage?
        if flights[flight.key] === flight {
            flights.removeValue(forKey: flight.key)
            if let image,
               !flight.isCancelled,
               flight.session == session,
               !flight.waiters.isEmpty {
                cache.setObject(image, for: flight.key)
                resultImage = image
            }
            completions = Array(flight.waiters.values)
            flight.waiters.removeAll()
        }
        lock.unlock()

        completions.forEach { deliver(resultImage, to: $0, session: flight.session) }
        lock.lock()
        activeWorkerCount = max(0, activeWorkerCount - 1)
        let nextFlights = takePendingFlightsLocked()
        lock.unlock()
        nextFlights.forEach(start)
    }

    private func takePendingFlightsLocked() -> [Flight] {
        var ready: [Flight] = []
        while activeWorkerCount < maximumConcurrentWorkers, !pendingFlights.isEmpty {
            let flight = pendingFlights.removeFirst()
            guard !flight.isCancelled, !flight.waiters.isEmpty,
                  flight.session == session, flights[flight.key] === flight else {
                continue
            }
            flight.state = .running
            activeWorkerCount += 1
            ready.append(flight)
        }
        return ready
    }

    private func deliver(
        _ image: CGImage?,
        to completion: @escaping @Sendable (CGImage?) -> Void,
        session deliverySession: UInt64? = nil
    ) {
        completion(isSessionCurrent(deliverySession) ? image : nil)
    }

    private func isSessionCurrent(_ deliverySession: UInt64?) -> Bool {
        guard let deliverySession else { return true }
        lock.lock()
        defer { lock.unlock() }
        return deliverySession == session
    }
}

private final class MacClippyFileThumbnailCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var image: CGImage?
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var waiter: MacClippyFileThumbnailWaiter?

    var value: CGImage? {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard !completed else {
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

    func install(_ waiter: MacClippyFileThumbnailWaiter) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            waiter.release()
            return
        }
        self.waiter = waiter
        lock.unlock()
    }

    func complete(_ image: CGImage?) {
        finish(image)
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ image: CGImage?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        self.image = image
        let continuation = self.continuation
        self.continuation = nil
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.release()
        continuation?.resume(returning: image)
    }
}
