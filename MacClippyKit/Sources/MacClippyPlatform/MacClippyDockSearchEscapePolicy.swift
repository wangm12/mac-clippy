import Foundation

public enum MacClippyDockSearchEscapePolicy {
    /// Escape clears a non-empty query first and stays in search. A second
    /// Escape with an empty query dismisses the dock.
    public static func clearsQueryFirst(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Leaving search for picker slams `isFloatingPanel` through level 0
    /// and reactivates the host, so one Escape flashes twice and still
    /// needs a second press to close.
    public static func dismissesDockWhenQueryIsEmpty() -> Bool {
        true
    }

    /// Maccy / PasteClip never mutate window level on Escape. First Esc
    /// cancels marked text natively; the next Esc only clears or hides.
    public static func shouldChangeOverlayLevel() -> Bool {
        false
    }
}
