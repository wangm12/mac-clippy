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
            guard let self else { return event }
            return self.routeKeyEvent(event)
        }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self else { return event }
            return self.routeKeyEvent(event)
        }
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.monitorGeneration == monitorGeneration else { return }
                guard MacClippyDockInputMethodPolicy.shouldHideWhenActiveSpaceChanges(
                    isSearchMode: self.interactionMode == .search,
                    hasMarkedText: self.searchFieldHasMarkedText,
                    didActivateApplicationForSearch: self.didActivateApplicationForSearch,
                    isOnActiveSpace: self.panel?.isOnActiveSpace ?? false,
                    isWithinGracePeriod: Date() < self.ignoreSpaceChangesUntil
                ) else { return }
                self.hide(reason: .spaceChange)
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
        ) { [weak self, weak dockPanel] _ in
            // AppKit posts this before the next window finishes becoming key.
            // Wait for the handoff so accessibility actions and internal panels
            // are not dismissed using an unrelated, stationary pointer.
            MacClippyMainHop.async {
                guard let self, let dockPanel else { return }
                self.handlePanelDidResignKey(
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
        traceE2EFocus("resign-key", location: pointerLocation)

        guard !dockPanel.isKeyWindow,
              detailsPanel?.isKeyWindow != true,
              previewPanel?.isKeyWindow != true,
              !snippetEditorWindow.isPresented,
              NSApp.modalWindow == nil,
              nativeMenuTrackingDepth == 0,
              !model.isFilterPopoverPresented else { return }

        // A key-window handoff can precede the active-space bookkeeping too.
        // Only assess a space departure after ruling out a completed handoff.
        if !dockPanel.isOnActiveSpace {
            hide(reason: .spaceChange)
            return
        }

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
                  isExternalWindowPresented: snippetEditorWindow.isPresented || model.isFilterPopoverPresented,
                  isSystemQuickLookVisible: isSystemQuickLookVisible
              ) else { return }
        // Candidate chrome is another process. Stealing key back here
        // dismisses the option list the user just clicked.
        if isInputMethodCandidate(at: pointerLocation) { return }
        if interactionMode == .search, (searchFieldHasMarkedText || searchFieldIsFirstResponder) { return }
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
        guard nativeMenuTrackingDepth == 0, !model.isFilterPopoverPresented else { return }
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
        if isInsidePreviewSurface(location) { return }
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
        traceE2EFocus("outside-pointer-hide", location: location)
        hide(reason: .outsideClick)
    }

    private func isInsidePreviewSurface(_ location: NSPoint) -> Bool {
        if let previewPanel, previewPanel.isVisible, previewPanel.frame.contains(location) { return true }
        return QLPreviewPanel.sharedPreviewPanelExists()
            && QLPreviewPanel.shared().isVisible && QLPreviewPanel.shared().frame.contains(location)
    }

    func focusResults() {
        guard !searchFieldHasMarkedText, model.currentCount > 0 else { return }
        if model.currentCount > 0 {
            model.focusedIndex = min(max(0, model.focusedIndex), model.currentCount - 1)
        }
        enterPickerMode()
    }

    func enterPickerMode() {
        guard MacClippyDockInputMethodPolicy.allowsPickerOverlayRestore(
            hasMarkedText: searchFieldHasMarkedText
        ) else { return }
        let leavingSearch = interactionMode == .search
        interactionMode = .picker
        isFullscreenSearchHost = hostApplicationIsFullscreen()
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
        } else if interactionMode == .modal {
            enterPickerMode()
        }
    }

    func enterSearchMode() {
        if interactionMode == .details {
            guard hideDetails() else { return }
        }
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
            takeKeyboardOwnership(of: dockPanel, restoreFirstResponder: false, retryLimit: 0)
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

            if expectedMode == .search, self.searchFieldHasMarkedText || self.searchFieldIsFirstResponder {
                return
            }

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
            hostIsFullscreen: isFullscreenSearchHost
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

}
