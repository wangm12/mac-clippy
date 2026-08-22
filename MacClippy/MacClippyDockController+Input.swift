import AppKit
import Foundation
import MacClippyPlatform
import QuartzCore
import QuickLookUI
import SwiftUI

extension MacClippyDockController {
    func startMonitors() {
        stopMonitors()
        guard let dockPanel = panel else { return }
        lastRoutedEventIdentity = nil
        let monitorGeneration = self.monitorGeneration
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in
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
                self.hide()
            }
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.monitorGeneration == monitorGeneration else { return }
                self.handleScreenParametersChanged()
            }
        }
        installKeyWindowObserver(for: dockPanel, monitorGeneration: monitorGeneration)
    }

    func installKeyWindowObserver(for dockPanel: MacClippyDockPanel, monitorGeneration: UInt) {
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: dockPanel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
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
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
            self.keyWindowObserver = nil
        }
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
        guard MacClippyDockOutsideClickPolicy.shouldDismiss(
            panelFrame: dockPanel.frame,
            clickLocation: location,
            isInsideExcludedWindow: false,
            ignoreUntil: ignoreOutsideClicksUntil,
            now: Date()
        ) else { return }
        hide()
    }

    func enterPickerMode() {
        interactionMode = .picker
        model.resetSearchFocus()
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
        interactionMode = .search
        if let dockPanel = panel, dockPanel.isVisible {
            takeKeyboardOwnership(of: dockPanel, restoreFirstResponder: false)
        }
        model.requestSearchFocus()
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

        dockPanel.orderFrontRegardless()
        dockPanel.makeKeyAndOrderFront(nil)
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

            dockPanel.orderFrontRegardless()
            dockPanel.makeKeyAndOrderFront(nil)
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
        let action = MacClippyDockKeyRouterPolicy.action(
            for: keyEvent,
            mode: interactionMode,
            hasCardFocus: model.focusedPreviewTarget != nil,
            hasMultipleSelection: model.hasMultipleSelection,
            detailsEditing: detailsEditing != .none,
            hasTextSelection: hasNativeTextSelection,
            isLoading: model.isLoading
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
