import Foundation

/// Every Carbon hotkey must surface `register()` failures. Swallowing
/// `try?` hides Input Monitoring problems for ignore-next.
public enum MacClippyHotKeyRegistrationPolicy {
    public enum EventDisposition: Equatable, Sendable {
        case handled
        case notHandled
    }

    public static func registrationFailureOperation(
        for role: MacClippyGlobalHotKeyRole
    ) -> String {
        switch role {
        case .clipboardDock:
            return "global_hotkey"
        case .ignoreNextCopy:
            return "ignore_next_copy_hotkey"
        }
    }

    /// Carbon runs same-target handlers last-installed-first and stops on
    /// `noErr`. A mismatched ID must continue the chain so the dock shortcut
    /// still fires after ignore-next is installed.
    public static func eventDisposition(
        parameterSucceeded: Bool,
        receivedSignature: UInt32,
        receivedID: UInt32,
        expectedSignature: UInt32,
        expectedID: UInt32
    ) -> EventDisposition {
        guard parameterSucceeded,
              receivedSignature == expectedSignature,
              receivedID == expectedID else {
            return .notHandled
        }
        return .handled
    }

    public static func shouldSurfaceSharedRegistrationBanner(
        for role: MacClippyGlobalHotKeyRole
    ) -> Bool {
        role == .clipboardDock
    }
}
