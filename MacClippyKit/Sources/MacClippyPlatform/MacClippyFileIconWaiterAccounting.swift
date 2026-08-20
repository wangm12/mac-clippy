import Foundation

/// Tracks how many waiters share one in-flight file-icon resolution so the
/// work can be cancelled when the last waiter leaves before the icon arrives.
public final class MacClippyFileIconWaiterAccounting: @unchecked Sendable {
    private let lock = NSLock()
    private var waiterCount = 0
    private var finished = false

    public init() {}

    public func addWaiter() {
        lock.lock()
        waiterCount += 1
        lock.unlock()
    }

    public func releaseWaiter() -> Bool {
        lock.lock()
        waiterCount = max(0, waiterCount - 1)
        let shouldCancel = waiterCount == 0 && !finished
        lock.unlock()
        return shouldCancel
    }

    public func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    public var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }
}
