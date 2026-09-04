import Foundation

/// Return pastes rich text by default. Shift-Return pastes plain text.
/// "Always paste as plain text" inverts that so Return is plain and
/// Shift-Return restores the original formatted payload.
public enum MacClippyPastePlainTextPolicy {
    public static func shouldPastePlain(alwaysPlain: Bool, shiftHeld: Bool) -> Bool {
        alwaysPlain != shiftHeld
    }
}
