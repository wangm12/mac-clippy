import AppKit
import Foundation

// Retry helper for lazy pasteboard data that is temporarily unavailable.
//
// NSPasteboardItem.data(forType:) and .string(forType:) can return nil for a
// few cycles after a changeCount bump when the provider is still materializing
// the representation (e.g. a lazy promise-backed provider). P0 capture retries
// a bounded number of times with a tiny sleep so a transiently-unavailable
// representation is still captured, while a permanently-unavailable one is
// skipped after the retry budget is exhausted so capture never hangs.
public enum MacClippyPasteboardReadRetry {
    public static let defaultAttempts: Int = 3
    public static let defaultDelay: TimeInterval = 0.01

    // Runs `operation` up to `attempts` times until it returns a non-nil
    // value. Sleeps `delay` seconds between attempts. Returns the first
    // non-nil value, or nil if every attempt returned nil. The operation is
    // always invoked at least once.
    public static func read<T>(
        attempts: Int = MacClippyPasteboardReadRetry.defaultAttempts,
        delay: TimeInterval = MacClippyPasteboardReadRetry.defaultDelay,
        _ operation: () -> T?
    ) -> T? {
        let safeAttempts = max(1, attempts)
        for attempt in 0..<safeAttempts {
            if let value = operation() {
                return value
            }
            if attempt < safeAttempts - 1, delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
        }
        return nil
    }
}

public typealias PasteboardReadRetry = MacClippyPasteboardReadRetry
