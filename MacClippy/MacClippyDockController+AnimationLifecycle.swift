import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import QuartzCore
import SwiftUI

extension MacClippyDockController {
    func discardPanelSurfaces() {
        invalidateAnimation()
        panel?.contentView?.layer?.removeAllAnimations()
        panelContentView?.backdropView.layer?.removeAllAnimations()
        panelContentView?.foregroundView.layer?.removeAllAnimations()
        panel?.animationBehavior = .none
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        panelContentView = nil
        hostingView = nil
        isClosing = false
    }

    func noteDisplayLifecycleEvent(_ event: MacClippyDisplayLifecycleEvent) {
        pendingDisplayEvent = event
        let panelExists = panel != nil
        let visible = isVisible
        if MacClippyDisplayGenerationPolicy.shouldDiscardHiddenPanel(
            event: event,
            panelExists: panelExists,
            isVisible: visible
        ) {
            discardPanelSurfaces()
            return
        }
        if MacClippyDisplayGenerationPolicy.shouldRebuildVisibleGlass(
            event: event,
            isVisible: visible
        ) {
            rebuildVisibleGlassSurfaces()
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
        panel?.animationBehavior = .none
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
        layer.shadowColor = nil
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowPath = nil
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
        contentView.layer?.shadowOpacity = 0
    }

    func animatePanelLayer(
        _ dockPanel: NSWindow,
        fromScale: CGFloat,
        toScale: CGFloat,
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

        containerLayer.removeAnimation(forKey: "macClippyPanelShadow")
        containerLayer.shadowOpacity = 0

        foregroundLayer.transform = CATransform3DMakeScale(toScale, toScale, 1)
    }

    func animatePanelOpacity(
        layer: CALayer?,
        from: Float,
        to toOpacity: Float,
        duration: TimeInterval,
        delay: TimeInterval = 0,
        timingFunction: CAMediaTimingFunction
    ) {
        guard let layer else { return }
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = from
        opacity.toValue = toOpacity
        opacity.beginTime = CACurrentMediaTime() + delay
        opacity.duration = duration
        opacity.timingFunction = timingFunction
        opacity.fillMode = .backwards
        layer.add(opacity, forKey: "macClippyPanelOpacity")
        layer.opacity = toOpacity
    }

    var shouldReduceMotion: Bool {
        reduceMotionOverride ?? MacClippyMotion.shouldReduceMotion(swiftUI: swiftUIReduceMotion)
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

    func toggle(source: MacClippyDockToggleSource = .hotKey) {
        let cursorScreen = screenContainingCursor()
        let panelScreen = panel.flatMap { screen(for: $0) }
        let isDifferentScreen = cursorScreen != nil && panelScreen != nil && cursorScreen != panelScreen
        switch MacClippyDockTogglePolicy.action(
            source: source,
            panelIsVisible: panel?.isVisible == true,
            isClosing: isClosing,
            isDifferentScreen: isDifferentScreen
        ) {
        case .show:
            if isClosing {
                invalidateAnimation()
                panel?.contentView?.layer?.removeAllAnimations()
                panelContentView?.backdropView.layer?.removeAllAnimations()
                panelContentView?.foregroundView.layer?.removeAllAnimations()
                isClosing = false
            }
            show()
        case .hide:
            hide()
        case .ignore:
            return
        }
    }
}
