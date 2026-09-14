import Foundation

public struct MacClippyHistoryRecencyKey: Equatable, Sendable {
    public let modified: Date
    public let lamport: UInt64
    public let id: String

    public init(modified: Date, lamport: UInt64, id: String) {
        self.modified = modified
        self.lamport = lamport
        self.id = id
    }
}

/// Newest-first history pages are already chronological. A page whose newest
/// item is older than the current tail can append without an O(n log n) sort.
public enum MacClippyHistoryPageMergePolicy {
    public static func isMoreRecent(
        _ lhs: MacClippyHistoryRecencyKey,
        than rhs: MacClippyHistoryRecencyKey
    ) -> Bool {
        if lhs.modified != rhs.modified {
            return lhs.modified > rhs.modified
        }
        if lhs.lamport != rhs.lamport {
            return lhs.lamport > rhs.lamport
        }
        return lhs.id > rhs.id
    }

    public static func shouldAppendOlderPage(
        existingOldest: MacClippyHistoryRecencyKey?,
        additionsNewest: MacClippyHistoryRecencyKey?
    ) -> Bool {
        guard let additionsNewest else { return true }
        guard let existingOldest else { return true }
        return !isMoreRecent(additionsNewest, than: existingOldest)
    }
}
