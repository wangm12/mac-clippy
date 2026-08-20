import Foundation

public enum MacClippyDockSearchEscapePolicy {
    /// Escape clears a non-empty query first and stays in search. A second
    /// Escape with an empty query leaves search mode.
    public static func clearsQueryFirst(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
