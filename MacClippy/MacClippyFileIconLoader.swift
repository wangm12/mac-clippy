import AppKit
import CoreGraphics
import ImageIO
import SwiftUI

import MacClippyPlatform

struct MacClippyDockPreviewFileIcon: View {
    let url: URL

    @State private var icon: CGImage?

    var body: some View {
        Group {
            if let icon {
                Image(decorative: icon, scale: 1, orientation: .up)
                    .resizable()
            } else {
                Image(systemName: "doc")
                    .resizable()
                    .padding(3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .task(id: url) {
            let resolvedIcon = await MacClippyFileIconLoader.image(for: url)
            guard !Task.isCancelled else { return }
            self.icon = resolvedIcon
        }
    }
}

private enum MacClippyFileIconLoader {
    fileprivate static let cache = MacClippyFileIconCache()
    fileprivate static let queue = DispatchQueue(
        label: "com.macallyouneed.macclippy.file-icon-resolution",
        qos: .utility,
        attributes: .concurrent
    )
    fileprivate static let resolutionSemaphore = DispatchSemaphore(value: 2)
    private static let requestLock = NSLock()
    // This is intentionally lock-protected shared state: icon requests can be
    // created by multiple SwiftUI tasks at once, while the cache and request
    // registry have no actor affinity.
    nonisolated(unsafe) private static var inFlight: [String: MacClippyFileIconInFlight] = [:]

    static func image(for url: URL) async -> CGImage? {
        let path = url.path
        if let cached = cache.object(for: path) {
            return cached
        }

        guard !Task.isCancelled else { return nil }
        let request = acquireRequest(for: path)
        let waiter = MacClippyFileIconWaiter(request: request, path: path)
        let resolved = await withTaskCancellationHandler(operation: {
            await request.task.value
        }, onCancel: {
            waiter.release()
        })
        waiter.release()
        return Task.isCancelled ? nil : resolved
    }

    private static func acquireRequest(for path: String) -> MacClippyFileIconInFlight {
        requestLock.lock()
        defer { requestLock.unlock() }
        if let existing = inFlight[path] {
            existing.addWaiter()
            return existing
        }
        let request = MacClippyFileIconInFlight(path: path)
        request.addWaiter()
        inFlight[path] = request
        return request
    }

    fileprivate static func releaseRequest(
        _ request: MacClippyFileIconInFlight,
        for path: String
    ) {
        let shouldCancel = request.releaseWaiter()
        if shouldCancel {
            request.cancel()
        }
        requestLock.lock()
        defer { requestLock.unlock() }
        if inFlight[path] === request, shouldCancel || request.isFinished {
            inFlight.removeValue(forKey: path)
        }
    }
}

private final class MacClippyFileIconWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let request: MacClippyFileIconInFlight
    private let path: String

    init(request: MacClippyFileIconInFlight, path: String) {
        self.request = request
        self.path = path
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        MacClippyFileIconLoader.releaseRequest(request, for: path)
    }
}

private final class MacClippyFileIconCache: @unchecked Sendable {
    private let storage = NSCache<NSString, CGImage>()

    init() {
        storage.countLimit = 256
        storage.totalCostLimit = 8 * 1_024 * 1_024
    }

    func object(for key: String) -> CGImage? {
        storage.object(forKey: key as NSString)
    }

    func setObject(_ image: CGImage, forKey key: String) {
        let cost = max(1, image.bytesPerRow * image.height)
        storage.setObject(image, forKey: key as NSString, cost: cost)
    }
}

private final class MacClippyFileIconInFlight: @unchecked Sendable {
    let task: Task<CGImage?, Never>
    private let state: MacClippyFileIconWaiterAccounting

    init(path: String) {
        let request = MacClippyFileIconRequest(path: path)
        let state = MacClippyFileIconWaiterAccounting()
        self.state = state
        task = Task.detached(priority: .utility) {
            let resolved = await request.resolve()
            state.markFinished()
            if let resolved {
                MacClippyFileIconLoader.cache.setObject(resolved, forKey: path)
            }
            return resolved
        }
    }

    func addWaiter() {
        state.addWaiter()
    }

    func releaseWaiter() -> Bool {
        state.releaseWaiter()
    }

    var isFinished: Bool {
        state.isFinished
    }

    func cancel() {
        task.cancel()
    }
}

private final class MacClippyFileIconRequest: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var workItem: DispatchWorkItem?
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var completed = false

    init(path: String) {
        self.path = path
    }

    func resolve() async -> CGImage? {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let workItem = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    MacClippyFileIconLoader.resolutionSemaphore.wait()
                    defer { MacClippyFileIconLoader.resolutionSemaphore.signal() }
                    let fileIcon = NSWorkspace.shared.icon(forFile: path)
                    let resolvedImage: CGImage?
                    if let data = fileIcon.tiffRepresentation,
                       let source = CGImageSourceCreateWithData(data as CFData, nil) {
                        resolvedImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
                    } else {
                        resolvedImage = nil
                    }
                    self.finish(resolvedImage)
                }

                lock.lock()
                if completed {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
                self.workItem = workItem
                lock.unlock()
                MacClippyFileIconLoader.queue.async(execute: workItem)
            }
        }, onCancel: { [weak self] in
            self?.cancel()
        })
    }

    private func finish(_ image: CGImage?) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        workItem = nil
        lock.unlock()
        continuation?.resume(returning: image)
    }

    private func cancel() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        workItem?.cancel()
        workItem = nil
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: nil)
    }
}
