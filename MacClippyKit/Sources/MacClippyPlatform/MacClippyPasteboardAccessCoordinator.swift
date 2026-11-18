import AppKit
import Foundation

/// Serializes in-process AppKit access to a named pasteboard across the
/// production reader, fixture writers, and paste injector.
public final class MacClippyPasteboardAccessCoordinator: @unchecked Sendable {
    private final class WeakCoordinator {
        weak var value: MacClippyPasteboardAccessCoordinator?

        init(_ value: MacClippyPasteboardAccessCoordinator) {
            self.value = value
        }
    }

    // Keep the mutable dictionary and its synchronization in one Sendable
    // owner. No caller can access registry entries without taking this lock.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: WeakCoordinator] = [:]

        func shared(for key: String) -> MacClippyPasteboardAccessCoordinator {
            lock.lock()
            defer { lock.unlock() }
            if let existing = entries[key]?.value { return existing }
            let coordinator = MacClippyPasteboardAccessCoordinator()
            entries[key] = WeakCoordinator(coordinator)
            entries = entries.filter { $0.value.value != nil }
            return coordinator
        }
    }

    private static let registry = Registry()

    private let lock = NSRecursiveLock()

    private init() {}

    public static func shared(for pasteboard: NSPasteboard) -> MacClippyPasteboardAccessCoordinator {
        registry.shared(for: pasteboard.name.rawValue)
    }

    public func withAccess<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
