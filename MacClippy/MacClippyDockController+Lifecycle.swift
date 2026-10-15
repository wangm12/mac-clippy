import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import QuartzCore
import SwiftUI

extension MacClippyDockController {
    func show() {
        guard let screen = screenContainingCursor() ?? NSScreen.main else { return }
        let session = prepareDockShow(on: screen)
        let dockPanel = makeDockPanel(frame: session.frame)
        prepareDockPanelForShow(
            dockPanel,
            frame: session.frame,
            reduceMotion: session.reduceMotion
        )
        presentDockPanel(dockPanel, reduceMotion: session.reduceMotion)
    }

    private func prepareDockShow(on screen: NSScreen) -> (frame: NSRect, reduceMotion: Bool) {
        let panelExisted = panel != nil
        if let pending = pendingDisplayEvent,
           MacClippyDisplayGenerationPolicy.shouldDiscardHiddenPanel(
               event: pending,
               panelExists: panelExisted,
               isVisible: panel?.isVisible == true
           ) {
            discardPanelSurfaces()
        }
        let skipGlassMotion = MacClippyDisplayGenerationPolicy.shouldSkipGlassMotion(
            pendingEvent: pendingDisplayEvent
        )
        skipGlassMotionForSession = skipGlassMotion
        pendingDisplayEvent = nil
        dismissPreviewImmediately()
        dismissDetailsImmediately()
        let frame = MacClippyDockFramePolicy.frame(
            for: screen.frame,
            hasMultipleSelection: model.hasMultipleSelection
        )
        model.clearActionFeedback()
        capturePasteTargetApplicationIfNeeded()
        didActivateApplicationForSearch = false
        isFullscreenSearchHost = hostApplicationIsFullscreen()
        interactionMode = .picker
        // Bump the session generation so any still-in-flight async completion
        // from a previous dock session cannot mutate state or close this newly
        // opened dock.
        model.beginSession()
        model.reload()
        MacClippyLog.notice(
            category: .ui,
            code: .dockPresented,
            operation: "dock_show",
            impact: MacClippyDockShowDiagnostics.impact(
                panelExisted: panelExisted,
                isLoading: model.isLoading,
                itemCount: model.historyItems.count,
                screenFrame: screen.frame,
                reduceMotion: shouldReduceMotion,
                skipGlassMotion: skipGlassMotion
            )
        )

        let reduceMotion = MacClippyPanelGlassMotionPolicy.shouldSkipAnimatedTransition(
            reduceMotion: shouldReduceMotion,
            skipGlassMotion: skipGlassMotion
        )
        return (frame, reduceMotion)
    }

    private func prepareDockPanelForShow(
        _ dockPanel: MacClippyDockPanel,
        frame: NSRect,
        reduceMotion: Bool
    ) {
        _ = beginAnimation(.showing)
        resetPanelAnimationState(dockPanel)
        isClosing = false
        dockPanel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        dockPanel.contentView?.autoresizingMask = [.width, .height]
        // Keep the window still. Window-frame slides resample glass every tick;
        // MacClippyPanelGlassMotionPolicy.shouldAnimateWindowFrame is false.
        dockPanel.setFrame(frame, display: false, animate: false)
        configurePanelLayer(dockPanel)
        dockPanel.interceptsPickerKeys = true
        model.resetSearchFocus()
        startMonitors()

        if reduceMotion {
            setPanelLayerState(
                dockPanel,
                backdropOpacity: 1,
                foregroundOpacity: 1,
                scale: 1,
                shadowOpacity: MacClippyMotion.panelShadowOpacity
            )
        } else {
            setPanelLayerState(
                dockPanel,
                backdropOpacity: MacClippyPanelGlassMotionPolicy.shouldFadeBackdrop() ? 0 : 1,
                foregroundOpacity: 0,
                scale: MacClippyMotion.panelContentScaleStart,
                shadowOpacity: MacClippyMotion.panelShadowOpacityStart
            )
        }
    }

    private func presentDockPanel(_ dockPanel: MacClippyDockPanel, reduceMotion: Bool) {
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
            guard MacClippyDockInputMethodPolicy.shouldEnterDeferredPickerMode(
                interactionModeIsSearch: self.interactionMode == .search
            ) else { return }
            self.enterPickerMode()
        }

        if !reduceMotion { animatePanelEntrance(on: dockPanel) }
        ignoreOutsideClicksUntil = Date().addingTimeInterval(MacClippyMotion.outsideClickGraceDuration)
        ignoreSpaceChangesUntil = Date().addingTimeInterval(MacClippyMotion.spaceChangeGraceDuration)
    }

    private func animatePanelEntrance(on dockPanel: MacClippyDockPanel) {
        let backdrop = MacClippyPanelGlassMotionPolicy.backdropOpacity(animated: true)
        if MacClippyPanelGlassMotionPolicy.shouldFadeBackdrop() {
            animatePanelOpacity(
                layer: panelContentView?.backdropView.layer,
                from: backdrop.from,
                to: backdrop.to,
                duration: MacClippyMotion.entranceDuration,
                timingFunction: MacClippyMotion.entranceTimingFunction
            )
        } else {
            panelContentView?.backdropView.layer?.opacity = backdrop.to
        }
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
            duration: MacClippyMotion.entranceDuration,
            timingFunction: MacClippyMotion.entranceTimingFunction
        )
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
                onEnterPickerMode: { [weak self] in self?.focusResults() },
                onPreview: { [weak self] in self?.showPreview() },
                onSearchModeChange: { [weak self] isSearching in
                    self?.setSearchMode(isSearching)
                },
                onSearchCompositionChange: { [weak self] composing in
                    guard let self, self.interactionMode == .search else { return }
                    guard MacClippyDockInputMethodPolicy.shouldAdjustOverlayForComposition() else {
                        return
                    }
                    self.applyOverlayLevel(allowsInputMethodCandidates: composing)
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
                onShowDetails: { [weak self] in self?.showCardDetails(id: $0, editing: $1) },
                onPreviewTarget: { [weak self] target in self?.showPreview(for: target) },
                onEditSnippet: { [weak self] snippet in self?.presentSnippetEditor(snippet: snippet) },
                onOpenHelp: { [weak self] in self?.openHelpAfterHide() }
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
            openSettingsHandler()
            return
        }
        guard !isClosing else { return }
        // Open Settings after focus ownership is released, before the panel's
        // exit animation starts, so the Settings window remains in front.
        // This avoids depending on animation completion timing.
        hide { [weak self] in
            self?.openSettingsHandler()
        }
    }

    func presentSnippetEditor(snippet: MacClippySnippetEntry? = nil) {
        snippetEditorWindow.present(snippet: snippet) { [weak self] name, trigger, body, folder, completion in
            guard let self else { return }
            let editorGeneration = self.snippetEditorWindow.generation
            let onSuccess: @MainActor @Sendable () -> Void = { [weak self] in
                guard self?.snippetEditorWindow.generation == editorGeneration else { return }
                completion(true)
                self?.snippetEditorWindow.close()
            }
            let onFailure: @MainActor @Sendable (String) -> Void = { [weak self] message in
                guard self?.snippetEditorWindow.generation == editorGeneration else { return }
                completion(false)
                self?.snippetEditorWindow.presentError(message)
            }
            if let snippet {
                self.model.updateSnippet(
                    id: snippet.id, draft: .init(name: name, trigger: trigger, body: body, folder: folder),
                    onSuccess: onSuccess, onFailure: onFailure
                )
            } else {
                self.model.createSnippet(name: name, trigger: trigger, body: body, folder: folder,
                                         onSuccess: onSuccess, onFailure: onFailure)
            }
        }
    }

    func openHelpAfterHide() {
        let defaults = model.defaults
        if panel?.isVisible == true {
            hide { MacClippyHelpWindow.shared.present(defaults: defaults) }
        } else {
            MacClippyHelpWindow.shared.present(defaults: defaults)
        }
    }

    func hide(reason: MacClippyDockHideReason = .command, completion: (() -> Void)? = nil) {
        guard let dockPanel = panel, dockPanel.isVisible, !isClosing else { return }
        guard hideDetails() else { return }
        traceE2EFocus("hide-\(reason)", location: NSEvent.mouseLocation)
        prepareForHide(reason: reason)
        completion?()
        animateHide(dockPanel, reason: reason)
    }

    private func prepareForHide(reason: MacClippyDockHideReason) {
        let leavingSearch = interactionMode == .search
        isClosing = true
        model.dismissModal()
        interactionMode = .picker
        isFullscreenSearchHost = false
        restorePasteTargetApplicationIfNeeded(
            leavingSearch: leavingSearch,
            isHiding: true,
            hideReason: reason
        )
        applyOverlayLevel(allowsInputMethodCandidates: false)
        hidePreview()
        stopMonitors()
        // End the session immediately so decoders and late cache writes cannot
        // outlive a hidden/reopened dock. Cards already holding a CGImage keep
        // their display value independently of the loader cache.
        model.endSession(resetCaches: true)
    }

    private func animateHide(_ dockPanel: MacClippyDockPanel, reason: MacClippyDockHideReason) {
        let transaction = beginAnimation(.hiding)
        let finish = hideCompletion(for: dockPanel, transaction: transaction)
        let reduceMotion = MacClippyPanelGlassMotionPolicy.shouldSkipAnimatedTransition(
            reduceMotion: shouldReduceMotion,
            skipGlassMotion: skipGlassMotionForSession,
            hideReason: reason
        )
        guard !reduceMotion else {
            finish()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            Task { @MainActor in
                finish()
            }
        }
        animateHideLayers(on: dockPanel)
        CATransaction.commit()
    }

    private func hideCompletion(
        for dockPanel: MacClippyDockPanel,
        transaction: MacClippyDockAnimationTransaction
    ) -> @MainActor @Sendable () -> Void {
        { [weak self, weak dockPanel] in
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
    }

    private func animateHideLayers(on dockPanel: MacClippyDockPanel) {
        if MacClippyPanelGlassMotionPolicy.shouldFadeBackdrop() {
            animatePanelOpacity(
                layer: panelContentView?.backdropView.layer,
                from: 1,
                to: 0,
                duration: MacClippyMotion.exitDuration,
                timingFunction: MacClippyMotion.exitTimingFunction
            )
        }
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
            duration: MacClippyMotion.exitDuration,
            timingFunction: MacClippyMotion.exitTimingFunction
        )
    }

    func rebuildVisibleGlassSurfaces() {
        guard isVisible, !isClosing else { return }
        guard let screen = screenContainingCursor() ?? NSScreen.main else { return }
        model.prepareForSurfaceRebuild()
        stopMonitors()
        discardPanelSurfaces()
        let frame = MacClippyDockFramePolicy.frame(
            for: screen.frame,
            hasMultipleSelection: model.hasMultipleSelection
        )
        let dockPanel = makeDockPanel(frame: frame)
        dockPanel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        dockPanel.contentView?.autoresizingMask = [.width, .height]
        dockPanel.setFrame(frame, display: false, animate: false)
        configurePanelLayer(dockPanel)
        resetPanelAnimationState(dockPanel)
        setPanelLayerState(
            dockPanel,
            backdropOpacity: 1,
            foregroundOpacity: 1,
            scale: 1,
            shadowOpacity: MacClippyMotion.panelShadowOpacity
        )
        dockPanel.interceptsPickerKeys = true
        dockPanel.makeKeyAndOrderFront(nil)
        takeKeyboardOwnership(of: dockPanel)
        startMonitors()
        handleScreenParametersChanged()
    }
}
