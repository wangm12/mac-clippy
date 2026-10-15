import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MacClippyPlatform
import QuartzCore
import QuickLookUI
import SwiftUI

extension MacClippyDockController {
    func capturePasteTargetApplicationIfNeeded() {
#if MACCLIPPY_E2E
        // The isolated harness only injects into its in-memory recipient. Never
        // discover or retain a user application's PID, including after a hide.
        pasteTargetApplication = NSRunningApplication.current
#else
        guard pasteTargetApplication == nil else { return }
        let front = NSWorkspace.shared.frontmostApplication
        if let front, MacClippyDockInputMethodPolicy.shouldCaptureHostApplication(
            hostBundleID: front.bundleIdentifier,
            ownBundleID: Bundle.main.bundleIdentifier
        ) {
            pasteTargetApplication = front
            return
        }
        if let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] {
            for win in windows {
                guard let layer = win[kCGWindowLayer as String] as? Int, layer == 0,
                      let pid = win[kCGWindowOwnerPID as String] as? Int32,
                      pid != NSRunningApplication.current.processIdentifier,
                      let app = NSRunningApplication(processIdentifier: pid),
                      MacClippyDockInputMethodPolicy.shouldCaptureHostApplication(
                          hostBundleID: app.bundleIdentifier,
                          ownBundleID: Bundle.main.bundleIdentifier
                      ) else {
                    continue
                }
                pasteTargetApplication = app
                return
            }
        }
#endif
    }

    func restorePasteTargetApplicationIfNeeded(
        leavingSearch: Bool,
        isHiding: Bool,
        hideReason: MacClippyDockHideReason = .command
    ) {
        let shouldRestore = MacClippyDockInputMethodPolicy.shouldRestoreHostApplication(
            leavingSearch: leavingSearch,
            isHiding: isHiding,
            didStealActivation: didActivateApplicationForSearch,
            hideReason: hideReason
        )
        if leavingSearch || isHiding {
            didActivateApplicationForSearch = false
        }
        defer {
            if isHiding {
                pasteTargetApplication = nil
            }
        }
        guard shouldRestore else { return }
        guard let host = pasteTargetApplication, !host.isTerminated else { return }
        guard host != NSRunningApplication.current else { return }
        activatePasteTarget(host)
    }

    func activateForFullscreenSearchIfNeeded() {
        isFullscreenSearchHost = hostApplicationIsFullscreen()
        guard !didActivateApplicationForSearch else { return }
        guard MacClippyDockInputMethodPolicy.shouldActivateApplication(
            isSearchMode: true,
            hostIsFullscreen: isFullscreenSearchHost
        ) else { return }
        NSApp.activate(
            ignoringOtherApps: MacClippyDockInputMethodPolicy.shouldActivateIgnoringOtherApps(
                isSearchMode: true,
                hostIsFullscreen: isFullscreenSearchHost
            )
        )
        didActivateApplicationForSearch = true
    }

    func hostApplicationIsFullscreen() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        return MacClippyDockInputMethodPolicy.isFullscreenHost(
            hostPID: hostProcessIdentifierForFullscreenCheck(),
            windows: windows,
            screens: NSScreen.screens.map(\.frame),
            accessibilityFullscreen: hostAccessibilityFullscreen()
        )
    }

    private func hostProcessIdentifierForFullscreenCheck() -> Int32? {
#if MACCLIPPY_E2E
        return NSRunningApplication.current.processIdentifier
#else
        if let pid = pasteTargetApplication?.processIdentifier {
            return pid
        }
        let front = NSWorkspace.shared.frontmostApplication
        if let front, MacClippyDockInputMethodPolicy.shouldCaptureHostApplication(
            hostBundleID: front.bundleIdentifier,
            ownBundleID: Bundle.main.bundleIdentifier
        ) {
            return front.processIdentifier
        }
        if let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] {
            for win in windows {
                guard let layer = win[kCGWindowLayer as String] as? Int, layer == 0,
                      let pid = win[kCGWindowOwnerPID as String] as? Int32,
                      pid != NSRunningApplication.current.processIdentifier else {
                    continue
                }
                return pid
            }
        }
        return nil
#endif
    }

    private func hostAccessibilityFullscreen() -> Bool? {
        guard AXIsProcessTrusted(),
              let pid = hostProcessIdentifierForFullscreenCheck() else {
            return nil
        }
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &focused
        ) == .success, let focused {
            let window = unsafeDowncast(focused, to: AXUIElement.self)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                window,
                "AXFullScreen" as CFString,
                &value
            ) == .success, let val = value as? NSNumber, val.boolValue {
                return true
            }
        }
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXWindowsAttribute as CFString,
            &windowsRef
        ) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }
        for window in windows {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(
                window,
                "AXFullScreen" as CFString,
                &value
            ) == .success,
               let val = value as? NSNumber,
               val.boolValue {
                return true
            }
        }
        return false
    }

    private func activatePasteTarget(_ host: NSRunningApplication) {
        _ = host.activate(from: NSRunningApplication.current)
    }

    func exposeSearchFieldToInputMethodIfNeeded() {
        guard !searchFieldHasMarkedText else { return }
        if MacClippyDockInputMethodPolicy.shouldPerformDeferredSearchFieldFocus(
            searchFieldIsFirstResponder: searchFieldIsFirstResponder,
            hasMarkedText: searchFieldHasMarkedText
        ) {
            focusSearchFieldEditor()
        }
        activateInputContextForFullscreenSearchIfNeeded()
    }

    private func activateInputContextForFullscreenSearchIfNeeded() {
        guard isFullscreenSearchHost,
              interactionMode == .search,
              !searchFieldHasMarkedText,
              MacClippyDockInputMethodPolicy.shouldActivateInputContextForFullscreenSearch()
        else { return }
        // Activate the context only. A deactivate/activate cycle dismisses
        // the candidate window while leaving marked text in the field.
        NSTextInputContext.current?.activate()
        if let contentView = panel?.contentView,
           let field = firstTextField(in: contentView),
           let editor = field.currentEditor() {
            editor.inputContext?.activate()
        }
    }

    var searchFieldIsFirstResponder: Bool {
        let responder = panel?.firstResponder
        if responder is NSTextView {
            return true
        }
        if let field = responder as? NSTextField {
            return field.isEditable
        }
        if let contentView = panel?.contentView,
           let field = firstTextField(in: contentView),
           let editor = field.currentEditor(),
           panel?.firstResponder === editor {
            return true
        }
        return false
    }

    func isInputMethodCandidate(at location: NSPoint) -> Bool {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        let quartz = MacClippyDockInputMethodPolicy.quartzPoint(
            fromCocoa: location,
            primaryHeight: primaryHeight
        )
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        return MacClippyDockInputMethodPolicy.isInputMethodCandidate(
            at: quartz,
            windows: windows
        )
    }

    func bringOverlayToKeyboard(
        _ dockPanel: MacClippyDockPanel,
        allowsInputMethodCandidates: Bool,
        attempt: Int
    ) {
        if MacClippyDockInputMethodPolicy.shouldReorderOverlayInFrontOfInputMethod(
            allowsInputMethodCandidates: allowsInputMethodCandidates,
            ownershipAttempt: attempt
        ) {
            dockPanel.orderFrontRegardless()
            dockPanel.makeKeyAndOrderFront(nil)
        } else {
            dockPanel.makeKey()
        }
    }
}
