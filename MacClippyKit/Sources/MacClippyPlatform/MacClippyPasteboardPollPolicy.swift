import CoreGraphics
import Foundation

public enum MacClippyPasteboardPollActivity: Equatable, Sendable {
    case foreground
    case background
}

/// Awake pasteboard poll cadence. Sleep still cancels the timer entirely
/// (`setPollingSuspended`); this only chooses how often to poll while awake.
///
/// Clippy is almost never the active app during a real copy, so this is
/// keyed off HID idle time and a short burst after an observed change —
/// not `NSApp.isActive`.
public enum MacClippyPasteboardPollPolicy {
    public static let foregroundInterval: TimeInterval = 0.05
    public static let backgroundInterval: TimeInterval = 0.40
    public static let userIdleThreshold: TimeInterval = 30
    public static let changeBurstDuration: TimeInterval = 2

    public static func activity(
        secondsSinceLastUserInput: TimeInterval,
        secondsSinceLastObservedChange: TimeInterval?
    ) -> MacClippyPasteboardPollActivity {
        if let secondsSinceLastObservedChange,
           secondsSinceLastObservedChange < changeBurstDuration {
            return .foreground
        }
        if secondsSinceLastUserInput < userIdleThreshold {
            return .foreground
        }
        return .background
    }

    public static func pollInterval(for activity: MacClippyPasteboardPollActivity) -> TimeInterval {
        switch activity {
        case .foreground:
            return foregroundInterval
        case .background:
            return backgroundInterval
        }
    }
}

public enum MacClippyUserInputIdle {
    public static func secondsSinceLastInput() -> TimeInterval {
        let mouse = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
        let key = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
        let flags = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .flagsChanged)
        return min(mouse, min(key, flags))
    }
}
