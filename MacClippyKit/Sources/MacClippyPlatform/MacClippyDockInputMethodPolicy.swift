import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Picker-mode `appendSearch` commits raw key characters. Chinese / Japanese /
/// Korean input methods need those keys for marked-text composition instead.
public enum MacClippyDockInputMethodPolicy {
    public static func letsInputMethodOwnTyping(
        hasMarkedText: Bool,
        inputSourceType: String?
    ) -> Bool {
        hasMarkedText || isInputMethodSource(type: inputSourceType)
    }

    public static func isInputMethodSource(type: String?) -> Bool {
        type == String(kTISTypeKeyboardInputMode)
    }

    public static var selectedKeyboardInputSourceChangedNotification: Notification.Name {
        Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
    }

    public static func currentKeyboardInputSourceType() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// Desktop search stays at `.mainMenu` so the system Dock cannot jump
    /// in front. System Pinyin's candidate bar is a fixed layer 20
    /// (Cherry Studio CGWindowList measurement). Fullscreen has no Dock,
    /// so search yields to `.floating` (3) — the only level they found
    /// that actually reveals the bar.
    public static func overlayLevel(
        allowsInputMethodCandidates: Bool,
        inputMethodCandidateLayers _: [Int] = [],
        hostIsFullscreen: Bool = false
    ) -> NSWindow.Level {
        if shouldYieldOverlayToInputMethodCandidates(
            isSearchMode: allowsInputMethodCandidates,
            hostIsFullscreen: hostIsFullscreen
        ) {
            return .floating
        }
        return .mainMenu
    }

    /// `canJoinAllSpaces` only paints the panel onto a fullscreen Space.
    /// System IME still attaches to the window's home Space (desktop).
    /// Maccy binds with `moveToActiveSpace` + `fullScreenAuxiliary` so the
    /// key window — and SCIM — live on the current Space.
    public static func collectionBehavior(
        hostIsFullscreen: Bool
    ) -> NSWindow.CollectionBehavior {
        [
            .fullScreenAuxiliary,
            .ignoresCycle,
            .canJoinAllApplications,
            .moveToActiveSpace,
            .stationary,
        ]
    }

    public static func shouldActivateInputContextForFullscreenSearch() -> Bool {
        true
    }

    public static func shouldYieldOverlayToInputMethodCandidates(
        isSearchMode: Bool,
        hostIsFullscreen: Bool
    ) -> Bool {
        false
    }

    public static func usesFloatingPanel(allowsInputMethodCandidates _: Bool) -> Bool {
        true
    }

    public static func shouldReorderOverlayInFrontOfInputMethod(
        allowsInputMethodCandidates _: Bool,
        ownershipAttempt _: Int
    ) -> Bool {
        true
    }

    public static func shouldAdjustOverlayForComposition() -> Bool {
        false
    }

    public static func shouldReassertOverlayAfterBecomingKey() -> Bool {
        true
    }

    /// IMK caches `NSTextInputClient.windowLevel` for the session. Re-applying
    /// the overlay on every key, or changing `isFloatingPanel`, destabilizes
    /// composition.
    public static func shouldReapplySearchOverlayOnKeyEvent() -> Bool {
        false
    }

    public static func allowsPickerOverlayRestore(hasMarkedText _: Bool) -> Bool {
        true
    }

    public static func shouldRefreshInputMethodWindowLevel(
        overlayChanged _: Bool,
        allowsInputMethodCandidates _: Bool
    ) -> Bool {
        false
    }

    /// Stay nonactivating (Maccy). `NSApp.activate` makes system Pinyin
    /// follow the app's desktop Space while the panel is only painted
    /// onto the fullscreen Space.
    public static func shouldActivateApplication(
        isSearchMode _: Bool,
        hostIsFullscreen _: Bool = false
    ) -> Bool {
        false
    }

    public static func shouldActivateIgnoringOtherApps(
        isSearchMode _: Bool,
        hostIsFullscreen _: Bool = false
    ) -> Bool {
        false
    }

    /// Electron / Cursor native fullscreen is often `screen.height` minus
    /// the 25–44pt menu bar/notch, not the full frame. A maximized desktop
    /// window also drops the Dock (~70pt) and must stay excluded.
    public static let fullscreenHeightSlop: CGFloat = 60

    /// A host window that matches a screen is fullscreen. A large browser
    /// window is not — activating over that is what pops the menu bar.
    /// `CGWindowList` is Quartz (top-left); `NSScreen.frame` is Cocoa
    /// (bottom-left). Compare size and `minX` only — `minY` is not in the
    /// same space on stacked displays.
    public static func isFullscreenHost(
        hostPID: Int32?,
        windows: [[String: Any]],
        screens: [CGRect],
        accessibilityFullscreen: Bool? = nil
    ) -> Bool {
        if accessibilityFullscreen == true { return true }
        guard let hostPID, !screens.isEmpty else { return false }
        return windows.contains { window in
            let pid = windowPID(window[kCGWindowOwnerPID as String])
            guard pid == hostPID else { return false }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = cgRect(from: bounds) else { return false }
            return screens.contains { screen in
                abs(rect.width - screen.width) <= 2
                    && abs(rect.height - screen.height) <= fullscreenHeightSlop
                    && abs(rect.minX - screen.minX) <= 2
            }
        }
    }

    /// A space change notification must never dismiss the dock during search or
    /// active marked-text composition, nor when the dock is on the active space
    /// or within the presentation grace period.
    public static func shouldHideWhenActiveSpaceChanges(
        isSearchMode: Bool = false,
        hasMarkedText: Bool = false,
        didActivateApplicationForSearch: Bool = false,
        isOnActiveSpace: Bool = false,
        isWithinGracePeriod: Bool = false
    ) -> Bool {
        if isWithinGracePeriod { return false }
        if isOnActiveSpace { return false }
        if isSearchMode || hasMarkedText { return false }
        return !didActivateApplicationForSearch
    }

    /// `CGWindowList` on every key hitches composition. Overlay is latched
    /// once when search opens.
    public static func shouldInspectCandidateWindowsOnKeyEvent() -> Bool {
        false
    }

    public static func shouldRestoreHostApplication(
        leavingSearch: Bool,
        isHiding: Bool,
        didStealActivation: Bool = true,
        hideReason: MacClippyDockHideReason = .command
    ) -> Bool {
        if isHiding {
            return hideReason != .outsideClick
        }
        return leavingSearch && didStealActivation
    }

    public static func shouldCaptureHostApplication(
        hostBundleID: String?,
        ownBundleID: String?
    ) -> Bool {
        guard let hostBundleID, !hostBundleID.isEmpty else { return false }
        guard let ownBundleID, !ownBundleID.isEmpty else { return true }
        return hostBundleID != ownBundleID
    }

    public static func shouldRefreshInputMethodContext(
        allowsInputMethodCandidates: Bool,
        searchFieldIsFirstResponder: Bool,
        hasMarkedText: Bool = false
    ) -> Bool {
        allowsInputMethodCandidates && searchFieldIsFirstResponder && !hasMarkedText
    }

    /// The first IME key is delivered after `enterSearchMode` returns.
    /// Re-focusing or cycling the input context on the next turn dismisses
    /// the candidate window while leaving marked text in the field.
    public static func shouldPerformDeferredSearchFieldFocus(
        searchFieldIsFirstResponder: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        !searchFieldIsFirstResponder && !hasMarkedText
    }

    public static func shouldReapplySearchOverlayForVisibleCandidates(
        currentLevel _: Int,
        candidateLayers _: [Int]
    ) -> Bool {
        false
    }

    public static func shouldEnterDeferredPickerMode(
        interactionModeIsSearch: Bool
    ) -> Bool {
        !interactionModeIsSearch
    }

    public static func shouldDismissForOutsideClick(
        isInsideInputMethodCandidate: Bool,
        isSearchMode: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        if isInsideInputMethodCandidate { return false }
        if isSearchMode && hasMarkedText { return false }
        return true
    }

    public static func isInputMethodCandidate(
        at point: CGPoint,
        windows: [[String: Any]]
    ) -> Bool {
        windows.contains { window in
            let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
            let name = (window[kCGWindowName as String] as? String) ?? ""
            guard isInputMethodCandidateWindow(owner: owner, name: name) else {
                return false
            }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = cgRect(from: bounds) else {
                return false
            }
            return rect.contains(point)
        }
    }

    public static func quartzPoint(
        fromCocoa point: CGPoint,
        primaryHeight: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private static func windowPID(_ value: Any?) -> Int32? {
        if let value = value as? Int32 { return value }
        if let value = value as? Int { return Int32(value) }
        if let value = value as? Int64 { return Int32(truncatingIfNeeded: value) }
        return nil
    }

    private static func cgRect(from bounds: [String: Any]) -> CGRect? {
        func number(_ key: String) -> CGFloat? {
            if let value = bounds[key] as? CGFloat { return value }
            if let value = bounds[key] as? Double { return CGFloat(value) }
            if let value = bounds[key] as? Int { return CGFloat(value) }
            return nil
        }
        guard let x = number("X"),
              let y = number("Y"),
              let width = number("Width"),
              let height = number("Height") else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    public static func isInputMethodCandidateWindow(owner: String, name: String) -> Bool {
        let blob = owner + " " + name
        return inputMethodOwnerTokens.contains { blob.localizedCaseInsensitiveContains($0) }
    }

    public static func inputMethodCandidateLayers(
        windows: [[String: Any]]
    ) -> [Int] {
        windows.compactMap { window in
            let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
            let name = (window[kCGWindowName as String] as? String) ?? ""
            guard isInputMethodCandidateWindow(owner: owner, name: name) else { return nil }
            return window[kCGWindowLayer as String] as? Int
        }
    }

    public static func currentInputMethodCandidateLayers() -> [Int] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return inputMethodCandidateLayers(windows: windows)
    }

    private static let inputMethodOwnerTokens = [
        "SCIM",
        "TCIM",
        "TYIM",
        "ChineseIM",
        "JapaneseIM",
        "KoreanIM",
        "VietnameseIM",
        "PluginIM",
        "PressAndHold",
        "CharacterPalette",
        "Input Method",
        "InputMethod",
    ]
}
