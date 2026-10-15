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
    public typealias PostEvent = (CGEvent, CGEventTapLocation) -> Void
    public typealias PostToProcess = (CGEvent, CGEvent, Int32) -> Void
    public typealias PostEventToProcess = (CGEvent, Int32) -> Void

    public static let tapLocation: CGEventTapLocation = .cgAnnotatedSessionEventTap

    private let postEvents: Post
    private let postEvent: PostEvent
    private let postEventsToProcess: PostToProcess?
    private let postEventToProcess: PostEventToProcess?

    public init(
        postEvents: @escaping Post = { keyDown, keyUp, tap in
            keyDown.post(tap: tap)
            keyUp.post(tap: tap)
        },
        postEvent: @escaping PostEvent = { event, tap in event.post(tap: tap) },
        postEventsToProcess: PostToProcess? = nil,
        postEventToProcess: PostEventToProcess? = nil
    ) {
        self.postEvents = postEvents
        self.postEvent = postEvent
        self.postEventsToProcess = postEventsToProcess
        self.postEventToProcess = postEventToProcess
    }

    @discardableResult
    public func post(
        keyCode: UInt16,
        gate: MacClippyPasteInjectionGate? = nil,
        targetProcessIdentifier: Int32? = nil
    ) -> Bool {
        post(keyCodes: [keyCode], gate: gate, targetProcessIdentifier: targetProcessIdentifier)
    }

    /// Prepares and admits a complete key sequence as one cancellable commit.
    /// Once admitted, every key pair is posted even if the gate closes; callers
    /// use this for edits that must be completed before their matching paste.
    @discardableResult
    public func post(
        keyCodes: [UInt16],
        gate: MacClippyPasteInjectionGate? = nil,
        targetProcessIdentifier: Int32? = nil
    ) -> Bool {
        let events = keyCodes.compactMap(makeEvents)
        guard events.count == keyCodes.count else { return false }
        let operation = {
            events.forEach { self.post($0, targetProcessIdentifier: targetProcessIdentifier) }
        }
        if let gate {
            return gate.withCommitGate(operation) != nil
        }
        operation()
        return true
    }

    /// Replays a captured event after a previously suppressed Tab delimiter.
    /// This runs on a worker queue so the event-tap callback never waits for
    /// event delivery or an injected test hook.
    public func post(event: CGEvent, targetProcessIdentifier: Int32? = nil) {
        if let targetProcessIdentifier {
            if let postEventToProcess {
                postEventToProcess(event, targetProcessIdentifier)
            } else {
                event.postToPid(pid_t(targetProcessIdentifier))
            }
        } else {
            postEvent(event, Self.tapLocation)
        }
    }

    private func post(_ events: KeyEvents, targetProcessIdentifier: Int32?) {
        guard let targetProcessIdentifier else {
            postEvents(events.keyDown, events.keyUp, Self.tapLocation)
            return
        }
        if let postEventsToProcess {
            postEventsToProcess(events.keyDown, events.keyUp, targetProcessIdentifier)
        } else {
            events.keyDown.postToPid(pid_t(targetProcessIdentifier))
            events.keyUp.postToPid(pid_t(targetProcessIdentifier))
        }
    }

    private struct KeyEvents {
        let keyDown: CGEvent
        let keyUp: CGEvent
    }

    private func makeEvents(_ keyCode: UInt16) -> KeyEvents? {
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
            return nil
        }
        return KeyEvents(keyDown: keyDown, keyUp: keyUp)
    }
}
