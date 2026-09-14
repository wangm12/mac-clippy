import Foundation

public enum MacClippyDockHideTeardownPolicy {
    /// Clearing thumbnail caches publishes `nil` into still-visible cards
    /// and hitches hide. Wait until the panel is ordered out.
    public static func shouldResetThumbnailCachesBeforeHideAnimation() -> Bool {
        false
    }

    /// Global monitors and resign-key already arrive on the main thread.
    /// An extra `Task` hop leaves the dock on screen for a full turn.
    public static func shouldDeferOutsideClickToNextMainActorTurn() -> Bool {
        false
    }
}
