import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MacClippyPlatform
import QuartzCore
import QuickLookUI
import SwiftUI

enum MacClippyDockInputDispatch {
    static func performOnMain(_ body: @escaping @MainActor () -> Void) {
        if MacClippyDockHideTeardownPolicy.shouldDeferOutsideClickToNextMainActorTurn() {
            MacClippyMainHop.async(body)
            return
        }
        MacClippyMainHop.performNowIfOnMain(body)
    }
}

extension MacClippyDockController {
    func startMonitors() {
        stopMonitors()
        guard let dockPanel = panel else { return }
        lastRoutedEventIdentity = nil
        let monitorGeneration = self.monitorGeneration
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MacClippyDockInputDispatch.performOnMain {
                guard let self, self.monitorGeneration == monitorGeneration, self.isVisible else { return }
                self.closeIfOutside(event)
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.closeIfOutside(event)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.routeKeyEvent(event) ?? event
        }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.routeKeyEvent(event) ?? event
        }
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.monitorGeneration == monitorGeneration else { return }
                guard MacClippyDockInputMethodPolicy.shouldHideWhenActiveSpaceChanges(
                    didActivateApplicationForSearch: self.didActivateApplicationForSearch
                ) else { return }
                self.hide()
            }
        }
        installKeyWindowObserver(for: dockPanel, monitorGeneration: monitorGeneration)
        installKeyboardInputSourceObserver()
    }

    func installKeyWindowObserver(for dockPanel: MacClippyDockPanel, monitorGeneration: UInt) {
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: dockPanel,
            queue: .main
        ) { [weak self] _ in
            MacClippyDockInputDispatch.performOnMain {
                self?.handlePanelDidResignKey(
                    dockPanel,
                    monitorGeneration: monitorGeneration,
                    pointerLocation: NSEvent.mouseLocation
                )
            }
        }
    }

    func handlePanelDidResignKey(
        _ dockPanel: MacClippyDockPanel,
        monitorGeneration: UInt,
        pointerLocation: NSPoint
    ) {
        guard monitorGeneration == self.monitorGeneration else { return }

        // A nonactivating panel can lose key status before the global monitor
        // observes the click in another app. Resolve the pointer location here
        // first so restoring key ownership does not keep an outside click from
        // dismissing the Dock.
        closeIfOutside(at: pointerLocation)
        guard isVisible,
              MacClippyDockKeyboardOwnershipPolicy.shouldRestoreKeyboard(
                  for: interactionMode,
                  isVisible: isVisible,
                  isClosing: isClosing,
                  isExternalWindowPresented: snippetEditorWindow.isPresented,
                  isSystemQuickLookVisible: isSystemQuickLookVisible
              ) else { return }
        // Candidate chrome is another process. Stealing key back here
        // dismisses the option list the user just clicked.
        if isInputMethodCandidate(at: pointerLocation) { return }
        if interactionMode == .search, searchFieldHasMarkedText { return }
        takeKeyboardOwnership(of: dockPanel)
    }

    func stopMonitors() {
        monitorGeneration &+= 1
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let keyUpMonitor { NSEvent.removeMonitor(keyUpMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
        keyMonitor = nil
        keyUpMonitor = nil
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
            self.spaceChangeObserver = nil
        }
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
            self.keyWindowObserver = nil
        }
        if let keyboardInputSourceObserver {
            DistributedNotificationCenter.default().removeObserver(keyboardInputSourceObserver)
            self.keyboardInputSourceObserver = nil
        }
        cachedKeyboardInputSourceType = nil
    }

    func installKeyboardInputSourceObserver() {
        cachedKeyboardInputSourceType = MacClippyDockInputMethodPolicy.currentKeyboardInputSourceType()
        keyboardInputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: MacClippyDockInputMethodPolicy.selectedKeyboardInputSourceChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cachedKeyboardInputSourceType = nil
            }
        }
    }

    func keyboardInputSourceType() -> String? {
        if let cachedKeyboardInputSourceType {
            return cachedKeyboardInputSourceType
        }
        let type = MacClippyDockInputMethodPolicy.currentKeyboardInputSourceType()
        cachedKeyboardInputSourceType = type
        return type
    }

    func closeIfOutside(_ event: NSEvent) {
        guard !snippetEditorWindow.owns(event: event) else { return }
        let location = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        closeIfOutside(at: location)
    }

    func closeIfOutside(at location: NSPoint) {
        guard let dockPanel = panel, dockPanel.isVisible else { return }
        guard !snippetEditorWindow.owns(location: location) else { return }
        if let detailsPanel, detailsPanel.isVisible, detailsPanel.frame.contains(location) {
            return
        }
        if dockPanel.frame.contains(location) {
            if interactionMode == .preview, !isSystemQuickLookVisible {
                hidePreview()
            } else if interactionMode == .details {
                hideDetails()
            }
            return
        }
        // The preview panel now receives mouse events for the chevron buttons.
        // A click inside the preview panel must not dismiss the dock before the
        // button action runs, so treat it as in-bounds here; clicks elsewhere
        // keep dismissing normally.
        if let previewPanel, previewPanel.isVisible, previewPanel.frame.contains(location) {
            return
        }
        if QLPreviewPanel.sharedPreviewPanelExists(),
           QLPreviewPanel.shared().isVisible,
           QLPreviewPanel.shared().frame.contains(location) {
            return
        }
        let isInsideInputMethodCandidate = isInputMethodCandidate(at: location)
        guard MacClippyDockInputMethodPolicy.shouldDismissForOutsideClick(
            isInsideInputMethodCandidate: isInsideInputMethodCandidate,
            isSearchMode: interactionMode == .search,
            hasMarkedText: searchFieldHasMarkedText
        ) else { return }
        guard MacClippyDockOutsideClickPolicy.shouldDismiss(
            panelFrame: dockPanel.frame,
            clickLocation: location,
            isInsideExcludedWindow: isInsideInputMethodCandidate,
            isInsideStatusItem: statusItemScreenFrame?()?.contains(location) == true,
            ignoreUntil: ignoreOutsideClicksUntil,
            now: Date()
        ) else { return }
        hide(reason: .outsideClick)
    }

    func enterPickerMode() {
        guard MacClippyDockInputMethodPolicy.allowsPickerOverlayRestore(
            hasMarkedText: searchFieldHasMarkedText
        ) else { return }
        let leavingSearch = interactionMode == .search
        interactionMode = .picker
        isFullscreenSearchHost = false
        applyOverlayLevel(allowsInputMethodCandidates: false)
        if leavingSearch,
           MacClippyDockSearchQueryWritePolicy.shouldClearQueryWhenLeavingSearch() {
            model.clearSearchQuery()
        }
        model.resetSearchFocus()
        restorePasteTargetApplicationIfNeeded(leavingSearch: leavingSearch, isHiding: false)
        guard let dockPanel = panel, dockPanel.isVisible else { return }
        takeKeyboardOwnership(of: dockPanel)
    }

    func setModalMode(_ isPresented: Bool) {
        if isPresented {
            interactionMode = .modal
        } else {
            enterPickerMode()
        }
    }

    func enterSearchMode() {
        if interactionMode == .preview {
            hidePreview()
        }
        if interactionMode == .search {
            capturePasteTargetApplicationIfNeeded()
            activateForFullscreenSearchIfNeeded()
            applyOverlayLevel(allowsInputMethodCandidates: true)
            exposeSearchFieldToInputMethodIfNeeded()
            return
        }
        capturePasteTargetApplicationIfNeeded()
        interactionMode = .search
        activateForFullscreenSearchIfNeeded()
        applyOverlayLevel(allowsInputMethodCandidates: true)
        if let dockPanel = panel, dockPanel.isVisible {
            takeKeyboardOwnership(of: dockPanel, restoreFirstResponder: false)
        }
        model.requestSearchFocus()
        focusSearchFieldEditor()
        if MacClippyDockInputMethodPolicy.shouldReassertOverlayAfterBecomingKey() {
            applyOverlayLevel(allowsInputMethodCandidates: true)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.interactionMode == .search else { return }
            self.exposeSearchFieldToInputMethodIfNeeded()
            if MacClippyDockInputMethodPolicy.shouldReassertOverlayAfterBecomingKey() {
                self.applyOverlayLevel(allowsInputMethodCandidates: true)
            }
        }
    }

    func takeKeyboardOwnership(
        of dockPanel: MacClippyDockPanel,
        restoreFirstResponder: Bool = true,
        attempt: Int = 0,
        retryLimit: Int = 3
    ) {
        guard dockPanel.isVisible, !isClosing else { return }
        guard MacClippyDockKeyboardOwnershipPolicy.shouldTakeKeyboardOwnership(
            isSystemQuickLookVisible: isSystemQuickLookVisible
        ) else { return }

        let allowsInputMethodCandidates = interactionMode == .search && searchFieldHasMarkedText
        bringOverlayToKeyboard(
            dockPanel,
            allowsInputMethodCandidates: allowsInputMethodCandidates,
            attempt: attempt
        )
        if MacClippyDockInputMethodPolicy.shouldReassertOverlayAfterBecomingKey() {
            applyOverlayLevel(allowsInputMethodCandidates: interactionMode == .search)
        }
        if restoreFirstResponder,
           MacClippyDockKeyboardOwnershipPolicy.shouldRestoreFirstResponder(for: self.interactionMode) {
            dockPanel.makeFirstResponder(dockPanel.contentView)
        }

        guard retryLimit > 0 else { return }

        let expectedMode = interactionMode
        let expectedMonitorGeneration = monitorGeneration
        DispatchQueue.main.async { [weak self, weak dockPanel] in
            guard let self,
                  let dockPanel,
                  dockPanel.isVisible,
                  !self.isClosing,
                  self.monitorGeneration == expectedMonitorGeneration,
                  self.interactionMode == expectedMode else { return }

            self.bringOverlayToKeyboard(
                dockPanel,
                allowsInputMethodCandidates: expectedMode == .search && self.searchFieldHasMarkedText,
                attempt: attempt + 1
            )
            if MacClippyDockInputMethodPolicy.shouldReassertOverlayAfterBecomingKey() {
                self.applyOverlayLevel(allowsInputMethodCandidates: expectedMode == .search)
            }
            if restoreFirstResponder,
               self.interactionMode == .picker || self.interactionMode == .preview {
                dockPanel.makeFirstResponder(dockPanel.contentView)
            }

            let ownsKeyboard = dockPanel.isKeyWindow
                && NSApp.keyWindow === dockPanel
            if !ownsKeyboard, attempt < retryLimit {
                self.takeKeyboardOwnership(
                    of: dockPanel,
                    restoreFirstResponder: restoreFirstResponder,
                    attempt: attempt + 1,
                    retryLimit: retryLimit
                )
            }
        }
    }

    func applyOverlayLevel(allowsInputMethodCandidates: Bool) {
        guard let panel else { return }
        let yield = MacClippyDockInputMethodPolicy.shouldYieldOverlayToInputMethodCandidates(
            isSearchMode: interactionMode == .search || allowsInputMethodCandidates,
            hostIsFullscreen: isFullscreenSearchHost
        )
        let adjustForComposition = MacClippyDockInputMethodPolicy.shouldAdjustOverlayForComposition()
        let candidateLayers = adjustForComposition && yield
            ? MacClippyDockInputMethodPolicy.currentInputMethodCandidateLayers()
            : []
        let level = MacClippyDockInputMethodPolicy.overlayLevel(
            allowsInputMethodCandidates: yield,
            inputMethodCandidateLayers: candidateLayers,
            hostIsFullscreen: isFullscreenSearchHost
        )
        let floating = MacClippyDockInputMethodPolicy.usesFloatingPanel(
            allowsInputMethodCandidates: allowsInputMethodCandidates
        )
        let behavior = MacClippyDockInputMethodPolicy.collectionBehavior(
            hostIsFullscreen: isFullscreenSearchHost && interactionMode == .search
        )
        if panel.collectionBehavior != behavior {
            panel.collectionBehavior = behavior
        }
        panel.pinnedOverlayLevel = level
        let overlayChanged = panel.isFloatingPanel != floating || panel.level != level
        guard overlayChanged else { return }
        // Keep this bit stable across composition; changing it resets the
        // window level and can invalidate the native input session.
        if panel.isFloatingPanel != floating {
            panel.isFloatingPanel = floating
        }
        if panel.level != level {
            panel.level = level
        }
    }

    func capturePasteTargetApplicationIfNeeded() {
        guard pasteTargetApplication == nil else { return }
        let front = NSWorkspace.shared.frontmostApplication
        guard MacClippyDockInputMethodPolicy.shouldCaptureHostApplication(
            hostBundleID: front?.bundleIdentifier,
            ownBundleID: Bundle.main.bundleIdentifier
        ) else { return }
        pasteTargetApplication = front
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

    private func activateForFullscreenSearchIfNeeded() {
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

    private func hostApplicationIsFullscreen() -> Bool {
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
        if let pid = pasteTargetApplication?.processIdentifier {
            return pid
        }
        let front = NSWorkspace.shared.frontmostApplication
        guard MacClippyDockInputMethodPolicy.shouldCaptureHostApplication(
            hostBundleID: front?.bundleIdentifier,
            ownBundleID: Bundle.main.bundleIdentifier
        ) else {
            return nil
        }
        return front?.processIdentifier
    }

    private func hostAccessibilityFullscreen() -> Bool? {
        guard AXIsProcessTrusted(),
              let pid = hostProcessIdentifierForFullscreenCheck() else {
            return nil
        }
        let app = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let window: AXUIElement
        if AXUIElementCopyAttributeValue(
            app,
            kAXFocusedWindowAttribute as CFString,
            &focused
        ) == .success, let focused {
            window = unsafeBitCast(focused, to: AXUIElement.self)
        } else {
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                app,
                kAXWindowsAttribute as CFString,
                &windowsRef
            ) == .success,
                  let windows = windowsRef as? [AXUIElement],
                  let first = windows.first else {
                return nil
            }
            window = first
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window,
            "AXFullScreen" as CFString,
            &value
        ) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private func activatePasteTarget(_ host: NSRunningApplication) {
        _ = host.activate(from: NSRunningApplication.current)
    }

    private func exposeSearchFieldToInputMethodIfNeeded() {
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
              MacClippyDockInputMethodPolicy.shouldActivateInputContextForFullscreenSearch()
        else { return }
        // Activate the context only. A deactivate/activate cycle dismisses
        // the candidate window while leaving marked text in the field.
        NSTextInputContext.current?.activate()
    }

    private var searchFieldIsFirstResponder: Bool {
        let responder = panel?.firstResponder
        if responder is NSTextView {
            return true
        }
        if let field = responder as? NSTextField {
            return field.isEditable
        }
        return false
    }

    private func isInputMethodCandidate(at location: NSPoint) -> Bool {
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

    private func bringOverlayToKeyboard(
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

    func setSearchMode(_ isSearching: Bool) {
        if isSearching {
            if interactionMode != .search {
                enterSearchMode()
            }
        } else if interactionMode == .search {
            enterPickerMode()
        }
    }

    func routeKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard panel?.isVisible == true else { return event }
        // The snippet editor is a separate AppKit window. Let its text fields
        // receive native typing and navigation instead of routing those events
        // through the Dock picker/search state machine.
        guard !snippetEditorWindow.owns(event: event) else { return event }
        // Keep the visible closing panel a keyboard sink until orderOut. This
        // prevents AppKit from forwarding the same key to an unrelated
        // responder during the short hide animation.
        if isClosing {
            return nil
        }
        let eventIdentity = ObjectIdentifier(event)
        if eventIdentity == lastRoutedEventIdentity {
            return nil
        }
        // The Preview panel is intentionally non-key so the Dock remains the
        // keyboard owner. Route image OCR selection directly before asking the
        // general picker policy for an action; otherwise a selected image can
        // lose ⌘C when AppKit has no native text responder.
        if routePreviewCommandCopy(event, eventIdentity: eventIdentity) {
            return nil
        }
        guard let keyEvent = dockKeyEvent(from: event) else { return event }
        noteSearchFieldClearKeys(event)
        if MacClippyDockInputMethodPolicy.shouldReapplySearchOverlayOnKeyEvent(),
           interactionMode == .search,
           event.type == .keyDown {
            applyOverlayLevel(allowsInputMethodCandidates: true)
        }
        let hasMarkedText = searchFieldHasMarkedText
        let action = MacClippyDockKeyRouterPolicy.action(
            for: keyEvent,
            mode: interactionMode,
            hasCardFocus: model.focusedPreviewTarget != nil,
            hasMultipleSelection: model.hasMultipleSelection,
            detailsEditing: detailsEditing != .none,
            hasTextSelection: hasNativeTextSelection,
            isLoading: model.isLoading,
            alwaysPastePlainText: MacClippyRetentionPreferences.alwaysPastePlainText(),
            letInputMethodOwnTyping: MacClippyDockInputMethodPolicy.letsInputMethodOwnTyping(
                hasMarkedText: hasMarkedText,
                inputSourceType: keyboardInputSourceType()
            ),
            hasMarkedText: hasMarkedText
        )
        if routeNativeCommandCopy(event, action: action, eventIdentity: eventIdentity) {
            return nil
        }
        let consumed = applyKeyAction(action)
        if consumed {
            lastRoutedEventIdentity = eventIdentity
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastRoutedEventIdentity == eventIdentity else { return }
                self.lastRoutedEventIdentity = nil
            }
        }
        return consumed ? nil : event
    }

    private func dockKeyEvent(from event: NSEvent) -> MacClippyDockKeyEvent? {
        switch event.type {
        case .keyDown:
            return .keyDown(
                keyCode: event.keyCode,
                characters: event.characters,
                modifiers: event.modifierFlags,
                isRepeat: event.isARepeat
            )
        case .keyUp:
            return .keyUp(keyCode: event.keyCode, modifiers: event.modifierFlags)
        default:
            return nil
        }
    }

    private func routeNativeCommandCopy(
        _ event: NSEvent,
        action: MacClippyDockKeyAction,
        eventIdentity: ObjectIdentifier
    ) -> Bool {
        guard action == .native,
              event.type == .keyDown,
              MacClippyDockKeyRouterPolicy.isCommandCopy(
                  keyCode: event.keyCode,
                  modifiers: event.modifierFlags
              ) else { return false }
        if let selectionHost = selectedPreviewSelectionHost,
           selectionHost.hasSelectedText {
            selectionHost.copySelectedText()
            lastRoutedEventIdentity = eventIdentity
            return true
        }
        guard let previewTextView = selectedPreviewTextView else { return false }
        previewTextView.copy(nil)
        lastRoutedEventIdentity = eventIdentity
        return true
    }

    private func routePreviewCommandCopy(
        _ event: NSEvent,
        eventIdentity: ObjectIdentifier
    ) -> Bool {
        guard interactionMode == .preview,
              event.type == .keyDown,
              MacClippyDockKeyRouterPolicy.isCommandCopy(
                  keyCode: event.keyCode,
                  modifiers: event.modifierFlags
              ),
              let selectionHost = selectedPreviewSelectionHost,
              selectionHost.hasSelectedText else {
            return false
        }
        selectionHost.copySelectedText()
        lastRoutedEventIdentity = eventIdentity
        return true
    }

    private func noteSearchFieldClearKeys(_ event: NSEvent) {
        guard event.type == .keyDown else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isDeleteKey = event.keyCode == 51 || event.keyCode == 117
        let isCommandA = event.keyCode == 0 && modifiers == [.command]
        guard MacClippyDockSearchQueryWritePolicy.notesSearchFieldUserEdit(
            isSearchMode: interactionMode == .search,
            isDeleteKey: isDeleteKey,
            isCommandA: isCommandA
        ) else { return }
        model.noteSearchFieldUserKeyEvent()
    }

    func focusSearchFieldEditor() {
        guard let contentView = panel?.contentView,
              let field = firstTextField(in: contentView) else { return }
        panel?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            panel?.makeFirstResponder(editor)
        }
    }

    private var searchFieldHasMarkedText: Bool {
        markedTextClient?.hasMarkedText() == true
    }

    private var markedTextClient: NSTextInputClient? {
        let responders: [NSResponder?] = [
            NSApp.keyWindow?.firstResponder,
            panel?.firstResponder,
        ]
        for responder in responders {
            if let client = responder as? NSTextInputClient {
                return client
            }
        }
        return nil
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    private var hasNativeTextSelection: Bool {
        if let selectionHost = selectedPreviewSelectionHost,
           selectionHost.hasSelectedText {
            return true
        }
        let responder = NSApp.keyWindow?.firstResponder
        if let textView = responder as? NSTextView {
            return textView.selectedRange.length > 0
        }
        if let textField = responder as? NSTextField {
            return textField.currentEditor()?.selectedRange.length ?? 0 > 0
        }
        return selectedPreviewTextView != nil
    }

    private var selectedPreviewSelectionHost: MacClippyPreviewTextSelectionHost? {
        guard previewPanel?.isVisible == true,
              let contentView = previewPanel?.contentView else { return nil }
        return firstSelectionHost(in: contentView)
    }

    private var selectedPreviewTextView: NSTextView? {
        guard previewPanel?.isVisible == true,
              let contentView = previewPanel?.contentView else { return nil }
        return firstSelectedTextView(in: contentView)
    }

    private func firstSelectedTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.selectedRange.length > 0 {
            return textView
        }
        for subview in view.subviews {
            if let selected = firstSelectedTextView(in: subview) {
                return selected
            }
        }
        return nil
    }

    private func firstSelectionHost(in view: NSView) -> MacClippyPreviewTextSelectionHost? {
        if let host = view as? MacClippyPreviewTextSelectionHost,
           host.hasSelectedText {
            return host
        }
        for subview in view.subviews {
            if let host = firstSelectionHost(in: subview) {
                return host
            }
        }
        return nil
    }

    func consumePanelKey(_ event: NSEvent) -> Bool {
        routeKeyEvent(event) == nil
    }
}
