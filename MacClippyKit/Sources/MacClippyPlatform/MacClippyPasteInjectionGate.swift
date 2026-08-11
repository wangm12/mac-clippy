import Foundation

/// Serializes cancellation with a pasteboard side effect. Closing the gate
/// waits for an injection already in progress to finish, then prevents every
/// later write or keyboard event from starting.
public final class MacClippyPasteInjectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    public init() {}

    public func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    @discardableResult
    public func withOpenGate<T>(_ operation: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        return operation()
    }
}
