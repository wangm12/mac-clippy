import Foundation

/// Marks a dock operation cancelled without waiting for work already admitted
/// to the system clipboard/event APIs. Callers must check the gate again after
/// every admitted side effect before starting another one.
public final class MacClippyPasteInjectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    public init() {}

    public func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed
    }

    @discardableResult
    public func withCommitGate<T>(_ operation: () -> T) -> T? {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return nil
        }
        // This check is the admission point for one synchronous side effect.
        // Do not hold the state lock over AppKit, event posting, focus IPC, or
        // user-provided hooks: close() must become visible immediately.
        lock.unlock()
        return operation()
    }

    /// Kept for source compatibility. The closure is admitted atomically with
    /// cancellation but executes without the state lock. It must represent one
    /// effect, and the caller must recheck `isOpen` before its next effect.
    @discardableResult
    public func withOpenGate<T>(_ operation: () -> T) -> T? {
        withCommitGate(operation)
    }
}
