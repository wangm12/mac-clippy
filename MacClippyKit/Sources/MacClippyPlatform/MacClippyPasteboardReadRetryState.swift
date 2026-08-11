import Foundation

import MacClippyCore

// Cross-poll retry state for lazy pasteboard provider data.
//
// NSPasteboardItem.data(forType:) can return nil for a few cycles after a
// changeCount bump when a lazy/promise-backed provider is still materializing
// the representation. The synchronous MacClippyPasteboardReadRetry helper
// retries within a single read() call, but that is not enough: the observer
// polls on a timer, and a provider that takes longer than the synchronous
// retry budget would have its advertised UTIs silently dropped on the first
// poll that saw the changeCount.
//
// This state object tracks, per changeCount, the advertised UTIs that were
// unavailable on the most recent read plus how many cross-poll attempts have
// been spent on them. The observer consults it on every poll so it can:
//   - withhold lastChangeCount advancement (and thus delivery) while a retry
//     is still in budget, and
//   - re-read the pending types from the underlying pasteboard on subsequent
//     polls via PasteboardReading.reread(...), and
//   - after the budget is exhausted, deliver the change with every still-
//     unavailable advertised UTI carried as an explicit .unavailable marker
//     instead of silently dropping the type.
//
// The state is deterministic and side-effect free apart from its own fields,
// so tests can drive it with injected readers and queues without real timers.
public final class MacClippyPasteboardReadRetryState {
    // One pending entry per changeCount. In practice only one changeCount is
    // pending at a time (the observer stops polling older changes once a new
    // changeCount arrives), but the dictionary keeps the state self-cleaning
    // and avoids hidden coupling to the observer's single-slot assumption.
    public struct Pending {
        public let changeCount: Int
        // Preserve the first full read so cross-poll retries can re-read only
        // the unavailable UTI slots instead of materializing every
        // representation again.
        public let originalChange: PasteboardChange?
        // (item index, uti) pairs that were advertised but unavailable.
        public let unavailableTypes: [(itemIndex: Int, uti: String)]
        public let attempts: Int

        public init(
            changeCount: Int,
            originalChange: PasteboardChange? = nil,
            unavailableTypes: [(itemIndex: Int, uti: String)],
            attempts: Int
        ) {
            self.changeCount = changeCount
            self.originalChange = originalChange
            self.unavailableTypes = unavailableTypes
            self.attempts = attempts
        }
    }

    public let maxAttempts: Int

    // The dictionary is accessed from the observer's poll() on the observer's
    // queue and from stop()/clearAll() on the caller's thread; the lock keeps
    // every access serialized so stop()'s clearAll() cannot race with an
    // in-flight poll() on another thread.
    private let lock = NSLock()
    private var pendingByChangeCount: [Int: Pending] = [:]

    public init(maxAttempts: Int = 4) {
        self.maxAttempts = max(1, maxAttempts)
    }

    // Records the advertised-but-unavailable types for a changeCount. Called
    // by the observer the first time it sees a new changeCount with missing
    // provider data. Resets the attempt counter to zero.
    public func record(changeCount: Int, unavailableTypes: [(itemIndex: Int, uti: String)]) {
        record(change: nil, changeCount: changeCount, unavailableTypes: unavailableTypes)
    }

    public func record(change: PasteboardChange, unavailableTypes: [(itemIndex: Int, uti: String)]) {
        record(change: change, changeCount: change.changeCount, unavailableTypes: unavailableTypes)
    }

    private func record(
        change: PasteboardChange?,
        changeCount: Int,
        unavailableTypes: [(itemIndex: Int, uti: String)]
    ) {
        lock.lock(); defer { lock.unlock() }
        guard !unavailableTypes.isEmpty else {
            pendingByChangeCount.removeValue(forKey: changeCount)
            return
        }
        pendingByChangeCount[changeCount] = Pending(
            changeCount: changeCount,
            originalChange: change,
            unavailableTypes: unavailableTypes,
            attempts: 0
        )
    }

    // Returns the pending entry for a changeCount, or nil when no retry is
    // in progress for that changeCount.
    public func pending(for changeCount: Int) -> Pending? {
        lock.lock(); defer { lock.unlock() }
        return pendingByChangeCount[changeCount]
    }

    // Increments the attempt counter for a changeCount and returns whether
    // the budget remains after this attempt. When false, the observer must
    // stop retrying and deliver the change with unavailable markers.
    @discardableResult
    public func incrementAttempts(for changeCount: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = pendingByChangeCount[changeCount] else { return false }
        let nextAttempts = entry.attempts + 1
        let updated = Pending(
            changeCount: changeCount,
            originalChange: entry.originalChange,
            unavailableTypes: entry.unavailableTypes,
            attempts: nextAttempts
        )
        pendingByChangeCount[changeCount] = updated
        return nextAttempts < maxAttempts
    }

    // Narrows the retry set as providers materialize individual UTI slots,
    // while preserving the original full change and attempt budget.
    public func updateUnavailableTypes(
        for changeCount: Int,
        unavailableTypes: [(itemIndex: Int, uti: String)]
    ) {
        lock.lock(); defer { lock.unlock() }
        guard let entry = pendingByChangeCount[changeCount] else { return }
        guard !unavailableTypes.isEmpty else {
            pendingByChangeCount.removeValue(forKey: changeCount)
            return
        }
        pendingByChangeCount[changeCount] = Pending(
            changeCount: entry.changeCount,
            originalChange: entry.originalChange,
            unavailableTypes: unavailableTypes,
            attempts: entry.attempts
        )
    }

    // Clears the pending entry for a changeCount once the observer has
    // delivered (or abandoned) that change.
    public func clear(changeCount: Int) {
        lock.lock(); defer { lock.unlock() }
        pendingByChangeCount.removeValue(forKey: changeCount)
    }

    // Drops every pending entry so a stopped/restarted observer never
    // inherits cross-poll retry state from a previous session. Safe to call
    // from any thread (e.g. the caller's thread in stop()) because the
    // dictionary is lock-protected; poll() takes the same lock on the
    // observer's queue.
    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        pendingByChangeCount.removeAll()
    }

    public var pendingChangeCount: Int? {
        lock.lock(); defer { lock.unlock() }
        return pendingByChangeCount.keys.sorted().last
    }

    public var hasPending: Bool {
        lock.lock(); defer { lock.unlock() }
        return !pendingByChangeCount.isEmpty
    }

    // Returns pending changeCounts strictly less than the supplied bound.
    // Used by the observer to drop stale retry state once a newer changeCount
    // has been delivered (changeCount is monotonic per pasteboard, so an
    // older pending entry can never be observed again).
    public func stalePendingChangeCounts(below changeCount: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        return pendingByChangeCount.keys.filter { $0 < changeCount }.sorted()
    }
}

public typealias PasteboardReadRetryState = MacClippyPasteboardReadRetryState

// Helpers for detecting which advertised UTIs in a PasteboardChange are
// currently unavailable (provider advertised the type but returned no Data
// and no string). Used by both the observer (to seed the retry state) and
// tests (to assert the unavailable set deterministically).
public enum MacClippyPasteboardAvailability {
    // Returns (itemIndex, uti) pairs for every advertised UTI whose payload
    // is unavailable in the change. A UTI is unavailable when the item
    // advertises it in `types` but neither data(forType:) nor
    // string(forType:) returns a value.
    public static func unavailableTypes(in change: PasteboardChange) -> [(itemIndex: Int, uti: String)] {
        var result: [(itemIndex: Int, uti: String)] = []
        for (index, item) in change.items.enumerated() {
            for type in item.types {
                if type != MacClippyPasteboardInputLimits.truncatedUTIMarker,
                   !item.oversizedTypes.contains(type),
                   item.data(forType: type) == nil,
                   item.string(forType: type) == nil {
                    result.append((itemIndex: index, uti: type))
                }
            }
        }
        return result
    }
}

public typealias PasteboardAvailability = MacClippyPasteboardAvailability
