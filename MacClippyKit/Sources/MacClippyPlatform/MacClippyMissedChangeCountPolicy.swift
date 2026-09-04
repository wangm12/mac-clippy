import Foundation

/// Walks pasteboard `changeCount` gaps so a poll that lands on N after last
/// seeing K can process K+1…N instead of only the latest generation.
public enum MacClippyMissedChangeCountPolicy {
    public static let defaultCatchUpLimit = 32

    public static func hasMissedGenerations(after lastSeen: Int, observed: Int) -> Bool {
        observed > lastSeen + 1
    }

    /// Change counts to process after `lastSeen`, oldest first, including
    /// `observed`. A gap larger than `limit` keeps the most recent counts so
    /// catch-up cannot stall a poll behind thousands of vanished generations.
    public static func catchUpChangeCounts(
        after lastSeen: Int,
        observed: Int,
        limit: Int = defaultCatchUpLimit
    ) -> [Int] {
        guard observed > lastSeen else { return [] }
        let available = observed - lastSeen
        let capped = min(max(limit, 1), available)
        let first = observed - capped + 1
        return Array(first...observed)
    }
}
