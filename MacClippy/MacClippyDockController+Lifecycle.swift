import AppKit
import Foundation
import MacClippyPlatform
import QuartzCore
import SwiftUI

extension MacClippyDockController {
    func toggle() {
        if isClosing {
            // A second shortcut during the short exit animation is an explicit
            // reopen intent. Invalidate the hide completion before rebuilding
            // the panel so the old transaction cannot order it out afterward.
            invalidateAnimation()
            panel?.contentView?.layer?.removeAllAnimations()
            panelContentView?.backdropView.layer?.removeAllAnimations()
            panelContentView?.foregroundView.layer?.removeAllAnimations()
            isClosing = false
            show()
            return
        }
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

        let dockPanel = makeDockPanel(frame: frame)
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
        let expectedMonitorGeneration = monitorGeneration
        DispatchQueue.main.async { [weak self, weak dockPanel] in
            guard let self,
                  let dockPanel,
                  dockPanel.isVisible,
                  !self.isClosing,
                  self.monitorGeneration == expectedMonitorGeneration else { return }
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

    private func makeDockPanel(frame: NSRect) -> MacClippyDockPanel {
        if let existing = panel {
            return existing
        }

        let dockPanel = MacClippyDockPanel(contentRect: frame)
        dockPanel.systemQuickLookHost = self
        systemQuickLookSession.handlePickerEvent = { [weak self] event in
            self?.handleSystemQuickLookEvent(event) ?? false
        }
        dockPanel.onPickerKey = { [weak self] event in
            self?.consumePanelKey(event) ?? false
        }
        let hosting = MacClippyDockHostingView(
            rootView: MacClippyDockView(
                model: model,
                onClose: { [weak self] in self?.hide() },
                onCreateSnippet: { [weak self] in self?.presentSnippetEditor() },
                onOpenSettings: { [weak self] in self?.openSettingsAfterHide() },
                onEnterPickerMode: { [weak self] in self?.enterPickerMode() },
                onPreview: { [weak self] in self?.showPreview() },
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
        return dockPanel
    }

    func openSettingsAfterHide() {
        guard panel?.isVisible == true else {
            (NSApp.delegate as? AppDelegate)?.openSettingsWindowFromDock()
            return
        }
        guard !isClosing else { return }
        // Open Settings after focus ownership is released, before the panel's
        // exit animation starts, so the Settings window remains in front.
        // This avoids depending on animation completion timing.
        hide { [weak self] in
            guard self != nil else { return }
            (NSApp.delegate as? AppDelegate)?.openSettingsWindowFromDock()
        }
    }

    func presentSnippetEditor() {
        snippetEditorWindow.present { [weak self] name, trigger, body, completion in
            guard let self else { return }
            self.model.createSnippet(
                name: name,
                trigger: trigger,
                body: body,
                onSuccess: { [weak self] in
                    completion(true)
                    self?.snippetEditorWindow.close()
                },
                onFailure: { [weak self] message in
                    completion(false)
                    self?.snippetEditorWindow.presentError(message)
                }
            )
        }
    }

    func hide(completion: (() -> Void)? = nil) {
        guard let dockPanel = panel, dockPanel.isVisible, !isClosing else { return }
        guard hideDetails() else { return }
        isClosing = true
        model.dismissModal()
        interactionMode = .picker
        hidePreview()
        stopMonitors()
        // Bump the session generation so an async batch completion that was
        // started while the dock was visible cannot mutate state or close a
        // dock that the user has just reopened.
        model.endSession()
        completion?()
        let transaction = beginAnimation(.hiding)
        let targetFrame = MacClippyMotion.offscreenPanelFrame(for: dockPanel.frame)
            let finish: @MainActor @Sendable () -> Void = { [weak self, weak dockPanel] in
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
        cancelPreviewRetry()
        // Explicitly invalidate model session/operation tokens before tearing
        // down windows. Shutdown must not rely on ARC timing to suppress a
        // queued paste or a late database completion.
        model.endSession()
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

    func beginAnimation(_ operation: MacClippyDockAnimationTransaction.Operation) -> MacClippyDockAnimationTransaction {
        animationGeneration = MacClippyDockAnimationLifecyclePolicy.nextGeneration(after: animationGeneration)
        let transaction = MacClippyDockAnimationTransaction(
            generation: animationGeneration,
            operation: operation
        )
        animationTransaction = transaction
        return transaction
    }

    func invalidateAnimation() {
        animationGeneration = MacClippyDockAnimationLifecyclePolicy.nextGeneration(after: animationGeneration)
        animationTransaction = nil
    }

    func resetPanelAnimationState(_ dockPanel: NSWindow) {
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

    func configurePanelLayer(_ dockPanel: NSWindow) {
        guard let layer = dockPanel.contentView?.layer else { return }
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: MacClippyMotion.panelShadowYOffset)
        layer.shadowRadius = MacClippyMotion.panelShadowRadius
        layer.shadowPath = CGPath(rect: layer.bounds, transform: nil)
    }

    func setPanelLayerState(
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

    func animatePanelLayer(
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

    func animatePanelOpacity(
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

    var shouldReduceMotion: Bool {
        MacClippyMotion.shouldReduceMotion(swiftUI: swiftUIReduceMotion)
    }

    // Show a short-lived floating copy toast in the center of the active screen.
    // Independent of the dock panel so it survives a dock close, matching how
    // paste feedback reads as a system-level indicator.

    func screenContainingCursor() -> NSScreen? {
        screen(containing: NSEvent.mouseLocation, in: NSScreen.screens)
    }

    func isFullScreenSpace(_ screen: NSScreen) -> Bool {
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        let tolerance: CGFloat = 1
        return abs(frame.minX - visibleFrame.minX) <= tolerance
            && abs(frame.minY - visibleFrame.minY) <= tolerance
            && abs(frame.width - visibleFrame.width) <= tolerance
            && abs(frame.height - visibleFrame.height) <= tolerance
    }

    func screen(for dockPanel: NSWindow) -> NSScreen? {
        let screens = NSScreen.screens
        if let matchingScreen = currentScreen(for: dockPanel, in: screens) {
            return matchingScreen
        }
        return screen(containing: dockPanel.frame.midPoint, in: screens)
            ?? NSScreen.main
    }

    func currentScreen(for dockPanel: NSWindow, in screens: [NSScreen]) -> NSScreen? {
        guard let currentScreen = dockPanel.screen else { return nil }
        return screens.first { $0.frame == currentScreen.frame }
    }

    func screen(
        containing point: CGPoint,
        in screens: [NSScreen]
    ) -> NSScreen? {
        let frames = screens.map(\.frame)
        guard let selectedFrame = MacClippyDisplayLayout.screenRect(containing: point, from: frames) else {
            return nil
        }
        return screens.first { $0.frame == selectedFrame }
    }

    func handleScreenParametersChanged() {
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

        if interactionMode == .details, let detailsPanel, detailsPanel.isVisible {
            detailsPanel.setFrame(detailsFrame(for: dockPanel), display: true, animate: false)
            detailsPanel.orderFrontRegardless()
        }
    }

    func updateDockFrame(hasMultipleSelection: Bool) {
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

        if interactionMode == .details, let detailsPanel, detailsPanel.isVisible {
            detailsPanel.setFrame(detailsFrame(for: dockPanel), display: true, animate: false)
            detailsPanel.orderFrontRegardless()
        }
    }
}
