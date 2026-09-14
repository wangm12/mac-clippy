import Foundation

/// Hop onto the main queue, or record the work so XCTest can flush it
/// without spinning the AppKit run loop.
///
/// After a test host has ordered `NSPanel`s on screen, `RunLoop.current.run`
/// can crash inside `_NSWindowTransformAnimation` dealloc. Unit tests enable
/// capture and drain these hops after background queues finish.
enum MacClippyMainHop {
    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var captureForTesting = false
        var pending: [Work] = []
    }

    private final class Work: @unchecked Sendable {
        var body: (@MainActor () -> Void)?

        init(_ body: @escaping @MainActor () -> Void) {
            self.body = body
        }

        func perform() {
            let body = self.body
            self.body = nil
            guard let body else { return }
            MainActor.assumeIsolated {
                body()
            }
        }
    }

    private static let store = Store()

    static var isCapturingForTesting: Bool {
        store.lock.lock()
        defer { store.lock.unlock() }
        return store.captureForTesting
    }

    static func setCaptureForTesting(_ enabled: Bool) {
        store.lock.lock()
        store.captureForTesting = enabled
        store.lock.unlock()
    }

    static func performNowIfOnMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            Work(body).perform()
            return
        }
        async(body)
    }

    static func async(_ body: @escaping @MainActor () -> Void) {
        let work = Work(body)
        store.lock.lock()
        if store.captureForTesting {
            store.pending.append(work)
            store.lock.unlock()
            return
        }
        store.lock.unlock()
        DispatchQueue.main.async {
            work.perform()
        }
    }

    static func flushCapturedWork() {
        while true {
            store.lock.lock()
            let items = store.pending
            store.pending.removeAll()
            store.lock.unlock()
            guard !items.isEmpty else { return }
            for item in items {
                item.perform()
            }
        }
    }
}
