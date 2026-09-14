import Foundation

public enum MacClippyDockHistoryRefreshPolicy {
    /// Match typed-search `scheduleReload()` so capture bursts coalesce instead
    /// of serializing a full page load per notification.
    public static let externalChangeDebounceNanoseconds: UInt64 = 120_000_000

    public static func shouldReloadForExternalHistoryChange(
        isSessionActive: Bool,
        isHistoryTab: Bool
    ) -> Bool {
        isSessionActive && isHistoryTab
    }
}
