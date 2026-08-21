import CoreGraphics
import Foundation

/// Posts the synthetic keystrokes snippet expansion needs: the Delete presses
/// that remove a typed trigger, and the delimiter restored when automatic
/// paste turns out to be unavailable.
///
/// Expansion is driven by a `.cgSessionEventTap`. Posting these keys at
/// `.cghidEventTap` (the default used for the Cmd+V paste chord) would send
/// them through that tap first, so the planner would observe its own deletes
/// and its own restored delimiter as fresh user typing. They are posted at
/// `.cgAnnotatedSessionEventTap` instead, which enters the login session after
/// the session tap point, so expander output is never fed back into trigger
/// detection.
public final class MacClippySnippetKeyPoster {
    public typealias Post = (CGEvent, CGEvent, CGEventTapLocation) -> Void

    public static let tapLocation: CGEventTapLocation = .cgAnnotatedSessionEventTap

    private let postEvents: Post

    public init(
        postEvents: @escaping Post = { keyDown, keyUp, tap in
            keyDown.post(tap: tap)
            keyUp.post(tap: tap)
        }
    ) {
        self.postEvents = postEvents
    }

    public func post(keyCode: UInt16) {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(keyCode),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(keyCode),
                  keyDown: false
              )
        else {
            return
        }
        postEvents(keyDown, keyUp, Self.tapLocation)
    }
}
