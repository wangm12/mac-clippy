import AppKit
import Foundation

// A short-lived write token/change-count sentinel that lets Mac Clippy
// suppress recapture of its own pasteboard writes without filtering any
// external content.
//
// Flow:
//   1. Before issuing a copy/paste/snippet write, the injector calls
//      `beginWrite(on:)` which records the pasteboard's current changeCount
//      and the next changeCount it expects to see after the write.
//   2. The injector performs the write (clearContents + setData), which bumps
//      the pasteboard changeCount.
//   3. The observer's poll sees a new changeCount, asks the sentinel whether
//      that changeCount belongs to a Mac Clippy write, and if so skips the
//      capture callback. The sentinel expires the token immediately so a
//      later external write to the same changeCount (impossible in practice
//      because changeCount is monotonic per pasteboard) cannot be hidden.
//
// The sentinel never inspects UTIs or app bundle IDs, so concealed,
// transient, custom, and unknown external representations are always
// captured. It only suppresses exact changeCount matches for writes that Mac
// Clippy itself issued.
// SAFETY: `pendingChangeCounts` is the sole mutable state and all access is
// protected by `lock`. `beginWrite` and `consume` must remain synchronous so
// a pasteboard write and its observer token are registered in one call path.
public final class MacClippyPasteboardWriteSentinel: @unchecked Sendable {
    private let lock = NSLock()
    // changeCount is monotonic per NSPasteboard instance, so a small ring of
    // pending tokens is enough to cover back-to-back writes (e.g. copy then
    // paste). Tokens are consumed on first match and expired on read.
    private var pendingChangeCounts: Set<Int> = []

    public init() {}

    // Records the changeCount the observer should skip. Called by the
    // injector on the main thread right before it performs the write; the
    // expected next changeCount is (current + 1) because clearContents bumps
    // by one and the subsequent setData does not bump again.
    public func beginWrite(expectedChangeCount changeCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        pendingChangeCounts.insert(changeCount)
    }

    // Returns true exactly once per registered changeCount so the observer
    // can skip that change. Subsequent calls for the same changeCount return
    // false, which keeps a single stale token from hiding a later external
    // write (the changeCount is monotonic so this is defensive only).
    public func consume(changeCount: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingChangeCounts.remove(changeCount) != nil
    }

    /// Removes a token when a stamped write did not reach the pasteboard.
    /// Without this cancellation path, a failed paste could leave an
    /// unconsumed token in the set until the observer was restarted.
    public func cancel(changeCount: Int) {
        lock.lock()
        pendingChangeCounts.remove(changeCount)
        lock.unlock()
    }

    // For tests and diagnostics: the number of unconsumed tokens currently
    // held. Real callers never need this.
    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingChangeCounts.count
    }

    // Drop every pending token. Used by the observer when it is stopped so a
    // restart does not inherit stale tokens from a previous session.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        pendingChangeCounts.removeAll()
    }
}

public typealias PasteboardWriteSentinel = MacClippyPasteboardWriteSentinel

// Convenience helper that performs the beginWrite/prepare/consume sequence in
// one call. The injector uses this so the sentinel token is registered before
// the pasteboard is touched and the write happens in the same main-thread
// turn. Returns the preparer result so callers can chain paste injection.
public enum MacClippyPasteboardWriteCoordinator {
    @discardableResult
    public static func write(
        _ content: MacClippyPasteboardContent,
        on pasteboard: NSPasteboard,
        sentinel: MacClippyPasteboardWriteSentinel,
        preparer: (MacClippyPasteboardContent, NSPasteboard) -> Bool = MacClippyPasteboardPreparer.prepare(_:on:)
    ) -> Bool {
        let expected = pasteboard.changeCount + 1
        sentinel.beginWrite(expectedChangeCount: expected)
        return preparer(content, pasteboard)
    }
}
