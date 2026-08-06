import AppKit
import Foundation
import MacClippyPlatform
import QuartzCore
import SwiftUI

struct MacClippyDockAnimationTransaction: Equatable {
    enum Operation: Equatable {
        case showing
        case hiding
    }

    let generation: UInt
    let operation: Operation
}

enum MacClippyDockTogglePolicy {
    static func shouldHide(panelIsVisible: Bool) -> Bool {
        panelIsVisible
    }
}

enum MacClippyDockAnimationLifecyclePolicy {
    static func nextGeneration(after generation: UInt) -> UInt {
        generation &+ 1
    }

    static func shouldApplyCompletion(
        for transaction: MacClippyDockAnimationTransaction,
        current: MacClippyDockAnimationTransaction?
    ) -> Bool {
        transaction == current
    }
}

enum MacClippyDockKeyboardOwnershipPolicy {
    static func shouldRestoreKeyboard(
        for mode: MacClippyDockInteractionMode,
        isVisible: Bool,
        isClosing: Bool
    ) -> Bool {
        guard isVisible, !isClosing else { return false }
        return mode == .picker || mode == .preview || mode == .modal
    }

    static func shouldRestoreFirstResponder(for mode: MacClippyDockInteractionMode) -> Bool {
        mode == .picker || mode == .preview
    }
}

@MainActor
final class MacClippySnippetEditorWindowCoordinator: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func present(onCreate: @escaping (String, String?, String) -> Void) {
        if let window {
            bringToFront(window)
            return
        }

        let hostingView = NSHostingView(
            rootView: MacClippyCreateSnippetEditor(
                onCreate: onCreate,
                onCancel: { [weak self] in self?.close() }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 410),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "New Snippet"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.delegate = self
        self.window = window

        window.center()
        bringToFront(window)
    }

    func close() {
        window?.close()
    }

    func presentError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Could not save snippet"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

@MainActor
final class MacClippyDockController {
    private let model: MacClippyDockModel
    private let snippetEditorWindow = MacClippySnippetEditorWindowCoordinator()
    private var panel: MacClippyDockPanel?
    private var panelContentView: MacClippyDockPanelContentView?
    private var hostingView: NSHostingView<MacClippyDockView>?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var keyMonitor: Any?
    private var keyUpMonitor: Any?
    private var spaceChangeObserver: NSObjectProtocol?
    private var screenParametersObserver: NSObjectProtocol?
    private var keyWindowObserver: NSObjectProtocol?
    private var ignoreOutsideClicksUntil = Date.distantPast
    private var isClosing = false
    private var monitorGeneration: UInt = 0
    private var animationGeneration: UInt = 0
    private var animationTransaction: MacClippyDockAnimationTransaction?
    private var previewPanel: MacClippyPreviewPanel?
    private var previewHostingView: NSHostingView<MacClippyDockPreviewView>?
    private var detailsPanel: MacClippyDetailsPanel?
    private var detailsHostingView: NSHostingView<MacClippyDetailsView>?
    private var details: MacClippyItemDetails?
    private var detailsEditing: MacClippyDetailsEditing = .none
    private var previewRequestID: UInt = 0
    private var previewAnimationGeneration: UInt = 0
    private var previewIsClosing = false
    private var interactionMode: MacClippyDockInteractionMode = .picker
    private var swiftUIReduceMotion = false
    // Local monitors normally consume picker events before AppKit dispatches
    // them to the panel. The panel remains a fallback for non-key windows and
    // event-routing edge cases, so remember the last consumed event object to
    // make the two paths idempotent without reading deprecated event metadata.
    private var lastRoutedEventIdentity: ObjectIdentifier?
    // Screen-level copy toast panel, independent of the dock panel so a copy
    // confirmation survives a dock close and reads as a system indicator.
    private var toastPanel: MacClippyToastPanel?
    private var toastDismissTask: Task<Void, Never>?

    init(runtime: MacClippyRuntime) {
        model = MacClippyDockModel(runtime: runtime)
    }

    var isVisible: Bool { panel?.isVisible == true && !isClosing }

    func toggle() {
        // The status-item click also passes through the dock's local outside-
        // click monitor. That monitor starts the hide animation first, so
        // `isVisible` is already false by the time this action is delivered.
        // Use the AppKit presentation state here so the same click cannot
        // immediately reopen a panel that is already on screen and closing.
        if MacClippyDockTogglePolicy.shouldHide(panelIsVisible: panel?.isVisible == true) {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let screen = screenContainingCursor() ?? NSScreen.main else { return }
        dismissPreviewImmediately()
        dismissDetailsImmediately()
        let frame = MacClippyDockFramePolicy.frame(
            for: screen.frame,
            hasMultipleSelection: model.hasMultipleSelection
        )
        model.clearActionFeedback()
        interactionMode = .picker
        // Bump the session generation so any still-in-flight async completion
        // from a previous dock session cannot mutate state or close this newly
        // opened dock.
        model.beginSession()
        model.reload()

        let dockPanel: MacClippyDockPanel
        if let existing = panel {
            dockPanel = existing
        } else {
            dockPanel = MacClippyDockPanel(contentRect: frame)
            dockPanel.onPickerKey = { [weak self] event in
                self?.consumePanelKey(event) ?? false
            }
            let hosting = NSHostingView(
                rootView: MacClippyDockView(
                    model: model,
                    onClose: { [weak self] in self?.hide() },
                    onCreateSnippet: { [weak self] in self?.presentSnippetEditor() },
                    onEnterPickerMode: { [weak self] in
                        self?.enterPickerMode()
                    },
                    onSearchModeChange: { [weak self] isSearching in
                        self?.setSearchMode(isSearching)
                    },
                    onModalPresentationChange: { [weak self] isPresented in
                        self?.setModalMode(isPresented)
                    },
                    onReduceMotionChange: { [weak self] reduceMotion in
                        self?.swiftUIReduceMotion = reduceMotion
                    },
                    onLayoutHeightChange: { [weak self] hasMultipleSelection in
                        self?.updateDockFrame(hasMultipleSelection: hasMultipleSelection)
                    },
                    onCopyToast: { [weak self] title in
                        self?.showCopyToast(title: title)
                    }
                )
            )
            hostingView = hosting
            let contentView = MacClippyDockPanelContentView(foregroundView: hosting)
            panelContentView = contentView
            dockPanel.contentView = contentView
            panel = dockPanel
        }
        _ = beginAnimation(.showing)
        resetPanelAnimationState(dockPanel)
        isClosing = false
        dockPanel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        dockPanel.contentView?.autoresizingMask = [.width, .height]
        dockPanel.setFrame(frame, display: false, animate: false)
        configurePanelLayer(dockPanel)
        dockPanel.interceptsPickerKeys = true
        model.resetSearchFocus()
        startMonitors()

        let reduceMotion = shouldReduceMotion
        if reduceMotion {
            setPanelLayerState(
                dockPanel,
                backdropOpacity: 1,
                foregroundOpacity: 1,
                scale: 1,
                shadowOpacity: MacClippyMotion.panelShadowOpacity
            )
        } else {
            // Move only the fixed frame's origin; the dock never animates its size.
            dockPanel.setFrame(MacClippyMotion.offscreenPanelFrame(for: frame), display: false, animate: false)
            setPanelLayerState(
                dockPanel,
                backdropOpacity: 0,
                foregroundOpacity: 0,
                scale: MacClippyMotion.panelContentScaleStart,
                shadowOpacity: MacClippyMotion.panelShadowOpacityStart
            )
        }

        dockPanel.makeKeyAndOrderFront(nil)
        takeKeyboardOwnership(of: dockPanel)
        // SwiftUI can restore the TextField responder when the panel becomes
        // key, after the pre-order reset above has already run. Clear it once
        // on the next main-run-loop turn so the first card owns Space/arrows
        // for every fresh ⌘⇧V session.
        DispatchQueue.main.async { [weak self, weak dockPanel] in
            guard let self, let dockPanel, dockPanel.isVisible, !self.isClosing else { return }
            self.enterPickerMode()
        }

        if !reduceMotion {
            animatePanelOpacity(
                layer: panelContentView?.backdropView.layer,
                from: 0,
                to: 1,
                duration: MacClippyMotion.entranceDuration,
                timingFunction: MacClippyMotion.entranceTimingFunction
            )
            animatePanelOpacity(
                layer: panelContentView?.foregroundView.layer,
                from: 0,
                to: 1,
                duration: MacClippyMotion.entranceDuration - MacClippyMotion.foregroundRevealDelay,
                delay: MacClippyMotion.foregroundRevealDelay,
                timingFunction: MacClippyMotion.entranceTimingFunction
            )
            animatePanelLayer(
                dockPanel,
                fromScale: MacClippyMotion.panelContentScaleStart,
                toScale: 1,
                fromShadowOpacity: MacClippyMotion.panelShadowOpacityStart,
                toShadowOpacity: MacClippyMotion.panelShadowOpacity,
                duration: MacClippyMotion.entranceDuration,
                timingFunction: MacClippyMotion.entranceTimingFunction
            )
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MacClippyMotion.entranceDuration
                context.timingFunction = MacClippyMotion.entranceTimingFunction
                dockPanel.animator().setFrame(frame, display: true)
            }
        }
        ignoreOutsideClicksUntil = Date().addingTimeInterval(MacClippyMotion.outsideClickGraceDuration)
    }

    private func presentSnippetEditor() {
        snippetEditorWindow.present { [weak self] name, trigger, body in
            guard let self else { return }
            self.model.createSnippet(
                name: name,
                trigger: trigger,
                body: body,
                onSuccess: { [weak self] in
                    self?.snippetEditorWindow.close()
                },
                onFailure: { [weak self] message in
                    self?.snippetEditorWindow.presentError(message)
                }
            )
        }
    }

    func hide() {
        guard let dockPanel = panel, dockPanel.isVisible, !isClosing else { return }
        isClosing = true
        model.dismissModal()
        interactionMode = .picker
        hidePreview()
        hideDetails()
        stopMonitors()
        // Bump the session generation so an async batch completion that was
        // started while the dock was visible cannot mutate state or close a
        // dock that the user has just reopened.
        model.endSession()
        let transaction = beginAnimation(.hiding)
        let targetFrame = MacClippyMotion.offscreenPanelFrame(for: dockPanel.frame)
        let finish = { [weak self, weak dockPanel] in
            guard let self, let dockPanel,
                  MacClippyDockAnimationLifecyclePolicy.shouldApplyCompletion(
                      for: transaction,
                      current: self.animationTransaction
            ) else { return }
            dockPanel.orderOut(nil)
            dockPanel.alphaValue = 1
            self.setPanelLayerState(
                dockPanel,
                backdropOpacity: 1,
                foregroundOpacity: 1,
                scale: 1,
                shadowOpacity: MacClippyMotion.panelShadowOpacity
            )
            dockPanel.interceptsPickerKeys = false
            self.animationTransaction = nil
            self.isClosing = false
        }

        if shouldReduceMotion {
            finish()
        } else {
            animatePanelOpacity(
                layer: panelContentView?.backdropView.layer,
                from: 1,
                to: 0,
                duration: MacClippyMotion.exitDuration,
                timingFunction: MacClippyMotion.exitTimingFunction
            )
            animatePanelOpacity(
                layer: panelContentView?.foregroundView.layer,
                from: 1,
                to: 0,
                duration: MacClippyMotion.exitDuration,
                timingFunction: MacClippyMotion.exitTimingFunction
            )
            animatePanelLayer(
                dockPanel,
                fromScale: 1,
                toScale: MacClippyMotion.panelContentScaleStart,
                fromShadowOpacity: MacClippyMotion.panelShadowOpacity,
                toShadowOpacity: MacClippyMotion.panelShadowOpacityStart,
                duration: MacClippyMotion.exitDuration,
                timingFunction: MacClippyMotion.exitTimingFunction
            )
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = MacClippyMotion.exitDuration
                context.timingFunction = MacClippyMotion.exitTimingFunction
                dockPanel.animator().setFrame(targetFrame, display: true)
            }, completionHandler: {
                Task { @MainActor in
                    finish()
                }
            })
        }
    }

    func cleanup() {
        model.dismissModal()
        snippetEditorWindow.close()
        stopMonitors()
        dismissPreviewImmediately()
        dismissDetailsImmediately()
        dismissCopyToast()
        invalidateAnimation()
        panel?.contentView?.layer?.removeAllAnimations()
        panelContentView?.backdropView.layer?.removeAllAnimations()
        panelContentView?.foregroundView.layer?.removeAllAnimations()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        panelContentView = nil
        hostingView = nil
        isClosing = false
    }

    private func beginAnimation(_ operation: MacClippyDockAnimationTransaction.Operation) -> MacClippyDockAnimationTransaction {
        animationGeneration = MacClippyDockAnimationLifecyclePolicy.nextGeneration(after: animationGeneration)
        let transaction = MacClippyDockAnimationTransaction(
            generation: animationGeneration,
            operation: operation
        )
        animationTransaction = transaction
        return transaction
    }

    private func invalidateAnimation() {
        animationGeneration = MacClippyDockAnimationLifecyclePolicy.nextGeneration(after: animationGeneration)
        animationTransaction = nil
    }

    private func resetPanelAnimationState(_ dockPanel: NSWindow) {
        dockPanel.contentView?.layer?.removeAllAnimations()
        panelContentView?.backdropView.layer?.removeAllAnimations()
        panelContentView?.foregroundView.layer?.removeAllAnimations()
        dockPanel.setFrame(dockPanel.frame, display: false, animate: false)
        dockPanel.alphaValue = 1
        setPanelLayerState(
            dockPanel,
            backdropOpacity: 1,
            foregroundOpacity: 1,
            scale: 1,
            shadowOpacity: MacClippyMotion.panelShadowOpacity
        )
    }

    private func configurePanelLayer(_ dockPanel: NSWindow) {
        guard let layer = dockPanel.contentView?.layer else { return }
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: MacClippyMotion.panelShadowYOffset)
        layer.shadowRadius = MacClippyMotion.panelShadowRadius
        layer.shadowPath = CGPath(rect: layer.bounds, transform: nil)
    }

    private func setPanelLayerState(
        _ dockPanel: NSWindow,
        backdropOpacity: Float,
        foregroundOpacity: Float,
        scale: CGFloat,
        shadowOpacity: Float
    ) {
        guard let contentView = dockPanel.contentView as? MacClippyDockPanelContentView else { return }
        contentView.backdropView.layer?.opacity = backdropOpacity
        contentView.foregroundView.layer?.opacity = foregroundOpacity
        contentView.foregroundView.layer?.transform = CATransform3DMakeScale(scale, scale, 1)
        contentView.layer?.shadowOpacity = shadowOpacity
    }

    private func animatePanelLayer(
        _ dockPanel: NSWindow,
        fromScale: CGFloat,
        toScale: CGFloat,
        fromShadowOpacity: Float,
        toShadowOpacity: Float,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction
    ) {
        guard let contentView = dockPanel.contentView as? MacClippyDockPanelContentView,
              let foregroundLayer = contentView.foregroundView.layer,
              let containerLayer = contentView.layer else { return }

        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = CATransform3DMakeScale(fromScale, fromScale, 1)
        scale.toValue = CATransform3DMakeScale(toScale, toScale, 1)
        scale.duration = duration
        scale.timingFunction = timingFunction
        foregroundLayer.add(scale, forKey: "macClippyPanelScale")

        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = fromShadowOpacity
        shadow.toValue = toShadowOpacity
        shadow.duration = duration
        shadow.timingFunction = timingFunction
        containerLayer.add(shadow, forKey: "macClippyPanelShadow")

        foregroundLayer.transform = CATransform3DMakeScale(toScale, toScale, 1)
        containerLayer.shadowOpacity = toShadowOpacity
    }

    private func animatePanelOpacity(
        layer: CALayer?,
        from: Float,
        to: Float,
        duration: TimeInterval,
        delay: TimeInterval = 0,
        timingFunction: CAMediaTimingFunction
    ) {
        guard let layer else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = from
        opacity.toValue = to
        opacity.beginTime = CACurrentMediaTime() + delay
        opacity.duration = duration
        opacity.timingFunction = timingFunction
        opacity.fillMode = .backwards
        layer.add(opacity, forKey: "macClippyPanelOpacity")
        layer.opacity = to
    }

    private func startMonitors() {
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
        keyWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: dockPanel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.monitorGeneration == monitorGeneration,
                      MacClippyDockKeyboardOwnershipPolicy.shouldRestoreKeyboard(
                          for: self.interactionMode,
                          isVisible: self.isVisible,
                          isClosing: self.isClosing
                      ) else { return }
                self.takeKeyboardOwnership(of: dockPanel)
            }
        }
    }

    private func stopMonitors() {
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

    private func closeIfOutside(_ event: NSEvent) {
        guard let dockPanel = panel, dockPanel.isVisible else { return }
        let location = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        if let detailsPanel, detailsPanel.isVisible, detailsPanel.frame.contains(location) {
            return
        }
        if dockPanel.frame.contains(location) {
            if interactionMode == .preview {
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
        guard MacClippyDockLifecyclePolicy.shouldDismissForOutsideClick(
            panelFrame: dockPanel.frame,
            clickLocation: location,
            ignoreUntil: ignoreOutsideClicksUntil,
            now: Date()
        ) else { return }
        hide()
    }

    private func enterPickerMode() {
        interactionMode = .picker
        model.resetSearchFocus()
        guard let dockPanel = panel, dockPanel.isVisible else { return }
        takeKeyboardOwnership(of: dockPanel)
    }

    private func setModalMode(_ isPresented: Bool) {
        if isPresented {
            interactionMode = .modal
        } else {
            enterPickerMode()
        }
    }

    private func enterSearchMode() {
        if interactionMode == .preview {
            hidePreview()
        }
        interactionMode = .search
        if let dockPanel = panel, dockPanel.isVisible {
            takeKeyboardOwnership(of: dockPanel, restoreFirstResponder: false)
        }
        model.requestSearchFocus()
    }

    private func takeKeyboardOwnership(
        of dockPanel: MacClippyDockPanel,
        restoreFirstResponder: Bool = true,
        attempt: Int = 0
    ) {
        guard dockPanel.isVisible, !isClosing else { return }

        dockPanel.orderFrontRegardless()
        dockPanel.makeKeyAndOrderFront(nil)
        if restoreFirstResponder,
           MacClippyDockKeyboardOwnershipPolicy.shouldRestoreFirstResponder(for: self.interactionMode) {
            dockPanel.makeFirstResponder(dockPanel.contentView)
        }

        let expectedMode = interactionMode
        DispatchQueue.main.async { [weak self, weak dockPanel] in
            guard let self,
                  let dockPanel,
                  dockPanel.isVisible,
                  !self.isClosing,
                  self.interactionMode == expectedMode else { return }

            dockPanel.orderFrontRegardless()
            dockPanel.makeKeyAndOrderFront(nil)
            if restoreFirstResponder,
               self.interactionMode == .picker || self.interactionMode == .preview {
                dockPanel.makeFirstResponder(dockPanel.contentView)
            }

            let ownsKeyboard = dockPanel.isKeyWindow
                && NSApp.keyWindow === dockPanel
            if !ownsKeyboard, attempt < 3 {
                self.takeKeyboardOwnership(
                    of: dockPanel,
                    restoreFirstResponder: restoreFirstResponder,
                    attempt: attempt + 1
                )
            }
        }
    }

    private func setSearchMode(_ isSearching: Bool) {
        if isSearching {
            if interactionMode != .search {
                enterSearchMode()
            }
        } else if interactionMode == .search {
            enterPickerMode()
        }
    }

    private func routeKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard panel?.isVisible == true else { return event }
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
        let keyEvent: MacClippyDockKeyEvent
        switch event.type {
        case .keyDown:
            keyEvent = .keyDown(
                keyCode: event.keyCode,
                characters: event.characters,
                modifiers: event.modifierFlags,
                isRepeat: event.isARepeat
            )
        case .keyUp:
            keyEvent = .keyUp(keyCode: event.keyCode, modifiers: event.modifierFlags)
        default:
            return event
        }
        let action = MacClippyDockKeyRouterPolicy.action(
            for: keyEvent,
            mode: interactionMode,
            hasCardFocus: model.focusedPreviewTarget != nil,
            hasMultipleSelection: model.hasMultipleSelection,
            detailsEditing: detailsEditing != .none,
            isLoading: model.isLoading
        )
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

    private func consumePanelKey(_ event: NSEvent) -> Bool {
        routeKeyEvent(event) == nil
    }

    private func applyKeyAction(_ action: MacClippyDockKeyAction) -> Bool {
        switch action {
        case .consume:
            return true
        case .native:
            return false
        case .dismissModal:
            model.dismissModal()
        case .enterSearch:
            enterSearchMode()
        case .exitSearch:
            enterPickerMode()
        case .closeDock:
            hide()
        case .showPreview:
            showPreview()
        case .hidePreview:
            hidePreview()
        case .showDetails:
            showDetails()
        case .hideDetails:
            hideDetails()
        case .editContent:
            beginDetailsEditing(.content)
        case .rename:
            beginDetailsEditing(.label)
        case .cancelDetailsEdit:
            cancelDetailsEditing()
        case let .moveFocus(direction):
            moveFocusedPreview(direction: direction)
        case let .extendRange(direction):
            model.extendRangeByStep(direction)
        case .paste:
            if model.hasMultipleSelection {
                model.pasteSelectedAll(completion: { [weak self] in self?.hide() })
            } else {
                model.pasteFocused(completion: { [weak self] in self?.hide() })
            }
        case let .appendSearch(text):
            setSearchMode(true)
            model.appendSearchText(text)
        case .deleteSearchCharacter:
            model.deleteSearchCharacter()
        case .selectAll:
            model.selectAllVisible()
        case .clearSelection:
            model.clearSelection()
        case .deleteSelection:
            model.deleteSelected()
        case .pinSelection:
            model.pinSelected()
        case let .activateShortcut(number):
            model.activateShortcut(number, completion: { [weak self] in self?.hide() })
        }
        return true
    }

    private func showPreview() {
        if interactionMode == .details {
            hideDetails()
        }
        guard let dockPanel = panel, dockPanel.isVisible else {
            return
        }
        model.ensureFocusedSelection()
        guard let target = model.focusedPreviewTarget else {
            if model.isLoading {
                retryPreviewWhenReady(attempt: 0)
            }
            return
        }
        guard let screen = screen(for: dockPanel) else {
            return
        }
        guard let previewFrame = frameForPreview(above: dockPanel.frame, on: screen) else {
            return
        }

        previewRequestID &+= 1
        let requestID = previewRequestID
        let preview: MacClippyPreviewPanel
        let shouldAnimate: Bool
        if let existing = previewPanel {
            preview = existing
            shouldAnimate = !existing.isVisible || previewIsClosing
        } else {
            preview = MacClippyPreviewPanel(contentRect: previewFrame)
            let hosting = NSHostingView(rootView: previewView(content: .loading))
            previewHostingView = hosting
            preview.contentView = hosting
            previewPanel = preview
            shouldAnimate = true
        }

        previewIsClosing = false
        previewAnimationGeneration &+= 1
        resetPreviewPanelState(preview)
        preview.setFrame(previewFrame, display: false, animate: false)
        preview.orderFrontRegardless()
        dockPanel.interceptsPickerKeys = true
        interactionMode = .preview
        model.isPreviewVisible = true
        // Keep keyboard ownership on the Dock. Preview remains mouse-enabled
        // for its chevrons, but must not steal selection/Space responder state.
        takeKeyboardOwnership(of: dockPanel)
        if shouldAnimate && !shouldReduceMotion {
            preview.alphaValue = 0
            preview.setFrame(
                previewFrame.offsetBy(dx: 0, dy: -MacClippyMotion.panelOffset),
                display: false,
                animate: false
            )
            // Snappy spring-feel entrance (response ~0.25): short duration with
            // a strong ease-out so the preview pops in quickly and settles.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                preview.animator().setFrame(previewFrame, display: true)
                preview.animator().alphaValue = 1
            }
        }

        model.loadPreview(for: target) { [weak self] result in
            guard let self,
                  self.previewRequestID == requestID,
                  self.interactionMode == .preview,
                  self.model.focusedPreviewTarget == target,
                  let hosting = self.previewHostingView else { return }
            switch result {
            case let .success(payload):
                hosting.rootView = self.previewView(content: Self.previewContent(for: payload))
            case .failure:
                hosting.rootView = self.previewView(content: .error)
            }
        }
    }

    private func retryPreviewWhenReady(attempt: Int) {
        guard attempt < 200,
              interactionMode == .picker,
              panel?.isVisible == true else { return }
        model.ensureFocusedSelection()
        if model.focusedPreviewTarget != nil {
            showPreview()
        } else if model.isLoading {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.retryPreviewWhenReady(attempt: attempt + 1)
            }
        }
    }

    private func refreshPreview() {
        guard interactionMode == .preview,
              let target = model.focusedPreviewTarget,
              let hosting = previewHostingView else { return }
        previewRequestID &+= 1
        let requestID = previewRequestID
        model.loadPreview(for: target) { [weak self] result in
            guard let self,
                  self.previewRequestID == requestID,
                  self.interactionMode == .preview,
                  self.model.focusedPreviewTarget == target else { return }
            switch result {
            case let .success(payload):
                hosting.rootView = self.previewView(content: Self.previewContent(for: payload))
            case .failure:
                hosting.rootView = self.previewView(content: .error)
            }
        }
    }

    // The single helper that moves model focus and refreshes the preview. Both
    // the keyboard arrows and the preview header's prev/next chevrons route
    // through here so the focused card highlight and the preview content stay
    // in sync. Wraparound is preserved by model.moveFocus(by:).
    private func moveFocusedPreview(direction: MacClippyDockSelectionDirection) {
        model.moveFocus(direction)
        if interactionMode == .details {
            refreshDetails()
        } else {
            refreshPreview()
        }
    }

    private func refreshDetails() {
        guard interactionMode == .details,
              let target = model.focusedItem else { return }
        let targetID = target.id
        model.loadDetails(for: targetID) { [weak self] result in
            guard let self,
                  self.interactionMode == .details,
                  self.model.focusedItem?.id == targetID else { return }
            guard case let .success(details) = result else { return }
            self.details = details
            self.detailsEditing = .none
            self.detailsHostingView?.rootView = self.detailsView(details: details, editing: .none)
        }
    }

    // Builds the preview SwiftUI view for a content case, wiring the prev/next
    // navigation callback and the metadata (source icon/name/time/char count)
    // from the focused item. Centralized so the show, refresh, and error paths
    // share the same callback wiring and metadata.
    private func previewView(content: MacClippyDockPreviewContent) -> MacClippyDockPreviewView {
        let meta = previewMetadata()
        return MacClippyDockPreviewView(
            content: content,
            metadata: meta,
            onNavigate: { [weak self] direction in
                self?.moveFocusedPreview(direction: direction == .previous ? .left : .right)
            },
            onCopy: { [weak self] in
                self?.model.copyFocused()
            },
            onDismiss: { [weak self] in
                self?.hidePreview()
            }
        )
    }

    // Resolve QuickLook-style metadata from the focused item: source app
    // presentation, relative timestamp, and character count of the preview.
    private func previewMetadata() -> MacClippyDockPreviewMetadata {
        guard let item = model.focusedItem else { return .unknown }
        let source = MacClippySourceAppResolver.presentation(for: item.meta.sourceAppBundleID)
        let time = MacClippyDockTimestampPolicy.relativeLabel(for: item.meta.modified)
        let chars = item.preview.count
        return MacClippyDockPreviewMetadata(
            sourceName: source.displayName,
            sourceIcon: source.icon,
            sourceAccent: source.accent,
            relativeTime: time,
            characterCount: chars
        )
    }

    private func hidePreview() {
        previewRequestID &+= 1
        if interactionMode == .preview {
            interactionMode = .picker
            model.resetSearchFocus()
        }
        model.isPreviewVisible = false
        panel?.interceptsPickerKeys = isVisible
        if let dockPanel = panel, dockPanel.isVisible {
            takeKeyboardOwnership(of: dockPanel)
        }
        guard let preview = previewPanel, preview.isVisible, !previewIsClosing else {
            previewIsClosing = false
            previewPanel?.orderOut(nil)
            return
        }

        previewIsClosing = true
        previewAnimationGeneration &+= 1
        let generation = previewAnimationGeneration
        let targetFrame = preview.frame.offsetBy(dx: 0, dy: -MacClippyMotion.panelOffset)
        let finish = { [weak self, weak preview] in
            guard let self, let preview, self.previewAnimationGeneration == generation else { return }
            preview.orderOut(nil)
            preview.alphaValue = 1
            self.previewIsClosing = false
        }

        if shouldReduceMotion {
            finish()
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = MacClippyMotion.exitDuration
                context.timingFunction = MacClippyMotion.exitTimingFunction
                preview.animator().setFrame(targetFrame, display: true)
                preview.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in finish() }
            })
        }
    }

    private func showDetails() {
        guard let dockPanel = panel, dockPanel.isVisible,
              let target = model.focusedItem else { return }
        dismissPreviewImmediately()
        interactionMode = .details
        detailsEditing = .none
        let frame = detailsFrame(for: dockPanel)
        let panel: MacClippyDetailsPanel
        if let existing = detailsPanel {
            panel = existing
        } else {
            panel = MacClippyDetailsPanel(contentRect: frame)
            detailsPanel = panel
        }
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        let targetID = target.id
        model.loadDetails(for: targetID) { [weak self, weak panel] result in
            guard let self, let panel,
                  self.interactionMode == .details,
                  self.model.focusedItem?.id == targetID else { return }
            switch result {
            case let .success(details):
                self.details = details
                self.detailsHostingView = NSHostingView(rootView: self.detailsView(details: details, editing: .none))
                panel.contentView = self.detailsHostingView
                panel.makeKey()
            case .failure:
                self.model.setErrorForDetails(MacClippyUserFacingError.itemLoad)
                self.hideDetails()
            }
        }
    }

    private func hideDetails() {
        detailsEditing = .none
        details = nil
        if interactionMode == .details {
            interactionMode = .picker
            model.resetSearchFocus()
        }
        detailsPanel?.orderOut(nil)
        detailsHostingView = nil
        panel?.interceptsPickerKeys = isVisible
        if let dockPanel = panel, dockPanel.isVisible {
            takeKeyboardOwnership(of: dockPanel)
        }
    }

    private func dismissDetailsImmediately() {
        detailsEditing = .none
        details = nil
        detailsPanel?.orderOut(nil)
        detailsPanel?.close()
        detailsPanel = nil
        detailsHostingView = nil
    }

    private func beginDetailsEditing(_ editing: MacClippyDetailsEditing) {
        guard interactionMode == .details, let details else { return }
        guard editing == .label || details.isEditable else { return }
        guard editing != .content
            || (details.textContent?.count ?? 0) <= MacClippyDockPreviewTextPolicy.maxRenderedCharacters else {
            model.setErrorForDetails("Content too large to edit inline — use Copy instead")
            return
        }
        detailsEditing = editing
        detailsHostingView?.rootView = detailsView(details: details, editing: editing)
        detailsPanel?.makeKey()
    }

    private func cancelDetailsEditing() {
        guard let details else { return }
        detailsEditing = .none
        detailsHostingView?.rootView = detailsView(details: details, editing: .none)
        detailsPanel?.makeKey()
    }

    private func detailsView(details: MacClippyItemDetails, editing: MacClippyDetailsEditing) -> MacClippyDetailsView {
        MacClippyDetailsView(
            details: details,
            editing: editing,
            onEditingChanged: { [weak self] isEditing in self?.detailsEditing = isEditing ? editing : .none },
            onEdit: { [weak self] in self?.beginDetailsEditing(.content) },
            onRename: { [weak self] in self?.beginDetailsEditing(.label) },
            onSaveContent: { [weak self] text in self?.saveDetailsContent(text) },
            onSaveLabel: { [weak self] label in self?.saveDetailsLabel(label) },
            onCancelEdit: { [weak self] in self?.cancelDetailsEditing() },
            onPreview: { [weak self] in self?.showPreview() },
            onCopy: { [weak self] in self?.model.copyFocused() },
            onPlainCopy: details.contentKind == .text || details.contentKind == .html || details.contentKind == .rtf
                ? { [weak self] in self?.model.copyFocused(plain: true) } : nil,
            onTransformCopy: details.isEditable
                ? { [weak self] transform in self?.model.copyFocused(transform: transform) } : nil,
            onTransformPaste: details.isEditable
                ? { [weak self] transform in self?.model.pasteFocused(transform: transform, completion: { self?.hide() }) } : nil,
            onPaste: { [weak self] in self?.model.pasteFocused(completion: { self?.hide() }) },
            onPin: { [weak self] in
                self?.model.togglePinFocused { [weak self] in self?.refreshDetails() }
            },
            onDelete: { [weak self] in self?.hideDetails(); self?.model.deleteFocused() },
            onClose: { [weak self] in self?.hideDetails() }
        )
    }

    private func saveDetailsContent(_ text: String) {
        guard let details else { return }
        guard (details.textContent?.count ?? 0) <= MacClippyDockPreviewTextPolicy.maxRenderedCharacters else {
            detailsEditing = .none
            detailsHostingView?.rootView = detailsView(details: details, editing: .none)
            model.setErrorForDetails("Content too large to edit inline — use Copy instead")
            return
        }
        model.editDetails(id: details.id, text: text) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.detailsEditing = .none
                self.showDetails()
            case .failure:
                self.model.setErrorForDetails(MacClippyUserFacingError.itemSave)
            }
        }
    }

    private func saveDetailsLabel(_ label: String) {
        guard let details else { return }
        model.renameDetails(id: details.id, label: label) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.detailsEditing = .none
                self.showDetails()
            case .failure:
                self.model.setErrorForDetails(MacClippyUserFacingError.itemSave)
            }
        }
    }

    private func detailsFrame(for dockPanel: NSWindow) -> NSRect {
        let size = NSSize(width: 600, height: 680)
        let screen = screen(for: dockPanel) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? dockPanel.frame
        var frame = NSRect(x: dockPanel.frame.maxX - size.width, y: dockPanel.frame.maxY + 12, width: size.width, height: size.height)
        if frame.maxY > visible.maxY { frame.origin.y = dockPanel.frame.minY - size.height - 12 }
        if frame.minX < visible.minX { frame.origin.x = visible.minX + 12 }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - size.width - 12 }
        return frame
    }

    private func dismissPreviewImmediately() {
        previewRequestID &+= 1
        previewAnimationGeneration &+= 1
        previewIsClosing = false
        interactionMode = .picker
        previewPanel?.contentView?.layer?.removeAllAnimations()
        previewPanel?.orderOut(nil)
        previewPanel?.close()
        previewPanel = nil
        previewHostingView = nil
    }

    private func resetPreviewPanelState(_ preview: NSWindow) {
        preview.contentView?.layer?.removeAllAnimations()
        preview.alphaValue = 1
    }

    private func frameForPreview(above dockFrame: NSRect, on screen: NSScreen) -> NSRect? {
        let spacing: CGFloat = 12
        let minimumY = max(screen.visibleFrame.minY, dockFrame.maxY + spacing)
        let availableHeight = screen.visibleFrame.maxY - minimumY
        let size = MacClippyPreviewFrameMetrics.preferredSize(
            visibleFrame: screen.visibleFrame,
            availableHeight: availableHeight
        )
        let preferredFrame = NSRect(
            x: dockFrame.midX - size.width / 2,
            y: dockFrame.maxY + 12,
            width: size.width,
            height: size.height
        )
        return MacClippyDisplayLayout.clampedPreviewFrame(
            preferredFrame,
            within: screen.visibleFrame,
            above: dockFrame
        )
    }

    private static func previewContent(for payload: MacClippyRuntimePreviewPayload) -> MacClippyDockPreviewContent {
        switch payload {
        case let .text(value): .text(value)
        case let .image(data): .image(data)
        case let .files(urls): MacClippyDockPreviewContentPolicy.content(forFiles: urls)
        }
    }

    private var shouldReduceMotion: Bool {
        MacClippyMotion.shouldReduceMotion(swiftUI: swiftUIReduceMotion)
    }

    // Show a short-lived floating copy toast in the center of the active screen.
    // Independent of the dock panel so it survives a dock close, matching how
    // paste feedback reads as a system-level indicator.
    private func showCopyToast(title: String) {
        let screen = screenContainingCursor() ?? NSScreen.main
        guard let screen else { return }

        let isFullScreen = isFullScreenSpace(screen)
        let toastView = MacClippyCopyToastView(
            title: title,
            showsShadow: !isFullScreen
        )
        let hostingView = NSHostingView(rootView: toastView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        let size = hostingView.fittingSize
        let clampedSize = NSSize(
            width: max(size.width + 32, 180),
            height: max(size.height + 12, 64)
        )

        let frame = NSRect(
            x: screen.visibleFrame.midX - clampedSize.width / 2,
            y: screen.visibleFrame.midY - clampedSize.height / 2,
            width: clampedSize.width,
            height: clampedSize.height
        )

        let toast: MacClippyToastPanel
        if let existing = toastPanel {
            toast = existing
        } else {
            toastPanel?.orderOut(nil)
            toast = MacClippyToastPanel(contentRect: frame)
            toastPanel = toast
        }
        toast.contentView = hostingView
        toast.contentView?.wantsLayer = true
        toast.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        toast.contentView?.layer?.isOpaque = false
        toast.hasShadow = false
        toast.invalidateShadow()
        toast.setFrame(frame, display: true)
        toast.orderFrontRegardless()

        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.toastPanel?.orderOut(nil)
        }
    }

    private func dismissCopyToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toastPanel?.orderOut(nil)
    }

    private func screenContainingCursor() -> NSScreen? {
        screen(containing: NSEvent.mouseLocation, in: NSScreen.screens)
    }

    private func isFullScreenSpace(_ screen: NSScreen) -> Bool {
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let tolerance: CGFloat = 1
        return abs(frame.minX - visibleFrame.minX) <= tolerance
            && abs(frame.minY - visibleFrame.minY) <= tolerance
            && abs(frame.width - visibleFrame.width) <= tolerance
            && abs(frame.height - visibleFrame.height) <= tolerance
    }

    private func screen(for dockPanel: NSWindow) -> NSScreen? {
        let screens = NSScreen.screens
        if let matchingScreen = currentScreen(for: dockPanel, in: screens) {
            return matchingScreen
        }
        return screen(containing: dockPanel.frame.midPoint, in: screens)
            ?? NSScreen.main
    }

    private func currentScreen(for dockPanel: NSWindow, in screens: [NSScreen]) -> NSScreen? {
        guard let currentScreen = dockPanel.screen else { return nil }
        return screens.first { $0.frame == currentScreen.frame }
    }

    private func screen(
        containing point: CGPoint,
        in screens: [NSScreen]
    ) -> NSScreen? {
        let frames = screens.map(\.frame)
        guard let selectedFrame = MacClippyDisplayLayout.screenRect(containing: point, from: frames) else {
            return nil
        }
        return screens.first { $0.frame == selectedFrame }
    }

    private func handleScreenParametersChanged() {
        guard let dockPanel = panel, dockPanel.isVisible, !isClosing else { return }

        let screens = NSScreen.screens
        let cursorScreen = screen(containing: NSEvent.mouseLocation, in: screens)
        let panelScreen = currentScreen(for: dockPanel, in: screens)
        let targetScreen = cursorScreen ?? panelScreen ?? NSScreen.main
        guard let targetScreen else { return }

        let dockFrame = MacClippyDockFramePolicy.frame(
            for: targetScreen.frame,
            hasMultipleSelection: model.hasMultipleSelection
        )
        let shouldKeepPreview = interactionMode == .preview && previewPanel?.isVisible == true
        let nextPreviewFrame = shouldKeepPreview
            ? frameForPreview(above: dockFrame, on: targetScreen)
            : nil

        invalidateAnimation()
        dockPanel.contentView?.frame = NSRect(origin: .zero, size: dockFrame.size)
        dockPanel.setFrame(dockFrame, display: false, animate: false)
        resetPanelAnimationState(dockPanel)
        configurePanelLayer(dockPanel)

        previewAnimationGeneration &+= 1
        previewIsClosing = false
        if let preview = previewPanel {
            if let nextPreviewFrame, shouldKeepPreview {
                resetPreviewPanelState(preview)
                preview.setFrame(nextPreviewFrame, display: false, animate: false)
                preview.orderFrontRegardless()
            } else {
                preview.orderOut(nil)
            }
        }
    }

    private func updateDockFrame(hasMultipleSelection: Bool) {
        guard let dockPanel = panel,
              dockPanel.isVisible,
              !isClosing,
              let targetScreen = screen(for: dockPanel) else { return }

        let dockFrame = MacClippyDockFramePolicy.frame(
            for: targetScreen.frame,
            hasMultipleSelection: hasMultipleSelection
        )
        guard dockPanel.frame.size != dockFrame.size else { return }

        let shouldKeepPreview = interactionMode == .preview && previewPanel?.isVisible == true
        let nextPreviewFrame = shouldKeepPreview
            ? frameForPreview(above: dockFrame, on: targetScreen)
            : nil

        // Keep the bottom edge anchored and resize without spatial motion. The
        // action row is a content-state change, not a panel entrance/exit.
        dockPanel.contentView?.frame = NSRect(origin: .zero, size: dockFrame.size)
        dockPanel.setFrame(dockFrame, display: true, animate: false)
        configurePanelLayer(dockPanel)

        if let preview = previewPanel {
            if let nextPreviewFrame, shouldKeepPreview {
                resetPreviewPanelState(preview)
                preview.setFrame(nextPreviewFrame, display: true, animate: false)
                preview.orderFrontRegardless()
            } else {
                preview.orderOut(nil)
            }
        }
    }
}

private enum MacClippyPreviewFrameMetrics {
    private static let widthFraction: CGFloat = 0.72
    private static let heightFraction: CGFloat = 0.72
    private static let minimumWidth: CGFloat = 560
    private static let minimumHeight: CGFloat = 440
    private static let maximumWidth: CGFloat = 960
    private static let maximumHeight: CGFloat = 720

    static func preferredSize(visibleFrame: CGRect, availableHeight: CGFloat) -> CGSize {
        let width = min(
            maximumWidth,
            max(minimumWidth, visibleFrame.width * widthFraction)
        )
        let height = min(
            maximumHeight,
            max(minimumHeight, availableHeight * heightFraction)
        )
        return CGSize(width: width, height: height)
    }
}

private extension CGRect {
    var midPoint: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
