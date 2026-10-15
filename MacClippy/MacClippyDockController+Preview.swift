import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import QuartzCore
import QuickLookUI
import SwiftUI
import os.signpost

extension MacClippyDockController: MacClippySystemQuickLookHosting {
    func showPreview(for requestedTarget: MacClippyDockPreviewTarget? = nil) {
        let explicitMetadata = requestedTarget.map { previewMetadata(for: $0) }
        if interactionMode == .details {
            guard hideDetails() else { return }
        }
        guard let dockPanel = panel, dockPanel.isVisible else {
            return
        }
        if requestedTarget == nil { model.ensureFocusedSelection() }
        guard let target = requestedTarget ?? model.focusedPreviewTarget else {
            if model.isLoading {
                retryPreviewWhenReady(attempt: 0)
            }
            return
        }
        cancelPreviewRetry()
        previewMetadataSnapshot = explicitMetadata ?? previewMetadata(for: target)
        previewTarget = target

        previewRequestID &+= 1
        dockPanel.interceptsPickerKeys = true
        interactionMode = .preview
        model.resetSearchFocus()
        model.isPreviewVisible = true
        presentPreview(for: target, requestID: previewRequestID, isOpening: true)
    }

    func retryPreviewWhenReady(attempt: Int) {
        cancelPreviewRetry()
        guard attempt < 200,
              interactionMode == .picker,
              panel?.isVisible == true else { return }

        let expectedMonitorGeneration = monitorGeneration
        let expectedRetryGeneration = previewRetryGeneration
        previewRetryTask = Task { @MainActor [weak self] in
            var currentAttempt = attempt
            while currentAttempt < 200 {
                guard let self,
                      !Task.isCancelled,
                      self.previewRetryGeneration == expectedRetryGeneration,
                      self.monitorGeneration == expectedMonitorGeneration,
                      self.interactionMode == .picker,
                      self.panel?.isVisible == true else { return }
                self.model.ensureFocusedSelection()
                if self.model.focusedPreviewTarget != nil {
                    self.previewRetryTask = nil
                    self.showPreview()
                    return
                }
                guard self.model.isLoading else {
                    self.previewRetryTask = nil
                    return
                }
                currentAttempt += 1
                do {
                    try await Task.sleep(nanoseconds: 30_000_000)
                } catch {
                    return
                }
            }
            self?.previewRetryTask = nil
        }
    }

    func cancelPreviewRetry() {
        previewRetryGeneration &+= 1
        previewRetryTask?.cancel()
        previewRetryTask = nil
    }

    func refreshPreview(for requestedTarget: MacClippyDockPreviewTarget? = nil) {
        guard interactionMode == .preview,
              let target = requestedTarget ?? model.focusedPreviewTarget else { return }
        previewRequestID &+= 1
        presentPreview(for: target, requestID: previewRequestID, isOpening: false)
    }

    func presentPreview(
        for target: MacClippyDockPreviewTarget,
        requestID: UInt,
        isOpening: Bool
    ) {
        if previewTarget != target { previewMetadataSnapshot = previewMetadata(for: target) }
        previewTarget = target
        let transition = MacClippyPreviewSurfacePolicy.transition(isOpening: isOpening)
        if case let .item(id) = target,
           let item = model.visibleItems.first(where: { $0.id == id }),
           MacClippySystemQuickLookPolicy.prefersSystemQuickLook(
               contentKind: item.contentKind,
               fileURLs: item.fileURLs
           ) {
            let urls = MacClippySystemQuickLookPolicy.existingFileURLs(in: item.fileURLs)
            presentSystemQuickLook(urls: urls, transition: transition)
            return
        }

        closeSystemQuickLook(animated: MacClippyPreviewSurfacePolicy.shouldAnimateSystemQuickLook(for: transition))
        presentCustomPreview(for: target, requestID: requestID, transition: transition)
    }

    func presentSystemQuickLook(urls: [URL], transition: MacClippyPreviewSurfaceTransition) {
        guard panel?.isVisible == true, !urls.isEmpty else { return }
        hideCustomPreviewSurface(
            resetToLoading: MacClippyPreviewSurfacePolicy.shouldResetCustomPreviewToLoading(for: transition)
        )
        isClosingSystemQuickLook = false
        systemQuickLookSession.setURLs(urls)
        model.clearPreviewError()
        finishPreviewPerformance(signpostID: previewPerformanceSignpostID)
        isSystemQuickLookVisible = true
        guard let previewPanel = QLPreviewPanel.shared() else { return }
        let action = MacClippySystemQuickLookPresentationPolicy.action(panelIsVisible: previewPanel.isVisible)
        if MacClippySystemQuickLookPresentationPolicy.shouldTakeDockKeyboard(for: action),
           let dockPanel = panel {
            takeKeyboardOwnership(of: dockPanel)
        }
        switch action {
        case .reload:
            previewPanel.reloadData()
            previewPanel.currentPreviewItemIndex = 0
        case .open:
            let animated = MacClippyPreviewSurfacePolicy.shouldAnimateSystemQuickLook(for: transition)
            performSystemQuickLookVisibilityChange(on: previewPanel, animated: animated) { panel in
                panel.updateController()
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    func presentCustomPreview(
        for target: MacClippyDockPreviewTarget,
        requestID: UInt,
        transition: MacClippyPreviewSurfaceTransition
    ) {
        guard let dockPanel = panel, dockPanel.isVisible else { return }
        guard let screen = screen(for: dockPanel) else { return }
        guard let previewFrame = frameForPreview(above: dockPanel.frame, on: screen) else {
            return
        }

        let isOpening = transition == .openSession
        let preview: MacClippyPreviewPanel
        let shouldAnimate: Bool
        if let existing = previewPanel {
            preview = existing
            shouldAnimate = isOpening && (!existing.isVisible || previewIsClosing)
        } else {
            preview = MacClippyPreviewPanel(contentRect: previewFrame)
            let hosting = MacClippyPreviewHostingView(rootView: previewView(content: .loading))
            previewHostingView = hosting
            preview.contentView = hosting
            previewPanel = preview
            shouldAnimate = isOpening
        }

        previewIsClosing = false
        previewAnimationGeneration &+= 1
        resetPreviewPanelState(preview)
        preview.setFrame(previewFrame, display: false, animate: false)
        preview.orderFrontRegardless()
        // In-app preview stays display-only. Dock keeps Space / Return.
        takeKeyboardOwnership(
            of: dockPanel,
            retryLimit: MacClippyPreviewSurfacePolicy.keyboardOwnershipRetryLimit(for: transition)
        )
        if let previousSignpostID = previewPerformanceSignpostID {
            MacClippyPerformance.end("preview_open", id: previousSignpostID)
        }
        let previewSignpostID = MacClippyPerformance.begin("preview_open")
        previewPerformanceSignpostID = previewSignpostID
        if shouldAnimate && !shouldReduceMotion {
            preview.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MacClippyMotion.entranceDuration
                context.timingFunction = MacClippyMotion.entranceTimingFunction
                preview.animator().alphaValue = 1
            }
        }

        model.loadPreview(for: target) { [weak self] result in
            guard let self else {
                MacClippyPerformance.end("preview_open", id: previewSignpostID)
                return
            }
            defer { self.finishPreviewPerformance(signpostID: previewSignpostID) }
            guard
                  self.previewRequestID == requestID,
                  self.interactionMode == .preview,
                  self.previewTarget == target,
                  let hosting = self.previewHostingView else { return }
            switch result {
            case let .success(payload):
                self.model.clearPreviewError()
                hosting.rootView = self.previewView(content: Self.previewContent(for: payload, id: target.recordID))
            case .failure:
                self.model.setPreviewError(MacClippyUserFacingError.itemLoad)
                hosting.rootView = self.previewView(content: .error)
            }
        }
    }

    func hideCustomPreviewSurface(resetToLoading: Bool) {
        if resetToLoading, previewHostingView != nil {
            previewHostingView?.rootView = previewView(content: .loading)
        }
        previewPanel?.orderOut(nil)
        previewIsClosing = false
    }

    func closeSystemQuickLook(animated: Bool) {
        guard isSystemQuickLookVisible
                || (QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible) else {
            isSystemQuickLookVisible = false
            return
        }
        isClosingSystemQuickLook = true
        isSystemQuickLookVisible = false
        systemQuickLookSession.setURLs([])
        if QLPreviewPanel.sharedPreviewPanelExists(),
           let previewPanel = QLPreviewPanel.shared() {
            performSystemQuickLookVisibilityChange(on: previewPanel, animated: animated) { panel in
                panel.orderOut(nil)
            }
        }
    }

    func performSystemQuickLookVisibilityChange(
        on panel: QLPreviewPanel,
        animated: Bool,
        _ body: (QLPreviewPanel) -> Void
    ) {
        let previousBehavior = panel.animationBehavior
        panel.animationBehavior = MacClippyPreviewSurfacePolicy.quickLookAnimationBehavior(animated: animated)
        body(panel)
        if animated {
            return
        }
        DispatchQueue.main.async {
            panel.animationBehavior = previousBehavior == .none ? .default : previousBehavior
        }
    }

    func acceptsSystemQuickLook(_ panel: QLPreviewPanel) -> Bool {
        isSystemQuickLookVisible || !systemQuickLookSession.urls.isEmpty
    }

    func beginSystemQuickLook(_ panel: QLPreviewPanel) {
        panel.dataSource = systemQuickLookSession
        panel.delegate = systemQuickLookSession
        panel.reloadData()
    }

    func endSystemQuickLook(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
        let programmatic = isClosingSystemQuickLook
        isClosingSystemQuickLook = false
        isSystemQuickLookVisible = false
        systemQuickLookSession.setURLs([])
        guard MacClippySystemQuickLookPresentationPolicy.shouldExitPreviewOnEnd(
            isProgrammaticClose: programmatic,
            customPreviewVisible: previewPanel?.isVisible == true
        ) else { return }
        guard interactionMode == .preview else { return }
        interactionMode = .picker
        model.isPreviewVisible = false
        model.resetSearchFocus()
        if let dockPanel = self.panel, dockPanel.isVisible {
            takeKeyboardOwnership(of: dockPanel)
        }
    }

    func handleSystemQuickLookEvent(_ event: NSEvent) -> Bool {
        routeKeyEvent(event) == nil
    }

    func hidePreview() {
        cancelPreviewRetry()
        previewRequestID &+= 1
        model.clearPreviewError()
        closeSystemQuickLook(
            animated: MacClippyPreviewSurfacePolicy.shouldAnimateSystemQuickLook(for: .closeSession)
        )
        // Ordering out an NSPanel does not necessarily remove its hosting view
        // from the SwiftUI hierarchy. Replace the root before the close
        // animation so image decode/Vision tasks are cancelled immediately and
        // cannot finish against a hidden Preview session.
        if previewHostingView != nil {
            previewHostingView?.rootView = previewView(content: .loading)
        }
        finishPreviewPerformance(signpostID: previewPerformanceSignpostID)
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
        let finish: @MainActor @Sendable () -> Void = { [weak self, weak preview] in
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
                preview.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in finish() }
            })
        }
    }

    func frameForPreview(above dockFrame: NSRect, on screen: NSScreen) -> NSRect? {
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

    static func previewContent(
        for payload: MacClippyRuntimePreviewPayload,
        id: RecordID
    ) -> MacClippyDockPreviewContent {
        switch payload {
        case let .text(value):
            switch value.kind {
            case let .color(swatch):
                .color(id: id, value: value.displayText, swatch: swatch)
            case .plain, .url, .json, .code:
                .text(id: id, value: value.displayText, kind: value.kind)
            }
        case let .richText(richText, plain, _): .richText(id: id, attributed: richText.attributed, plain: plain)
        case let .image(data): .image(id: id, data: data)
        case let .files(urls): MacClippyDockPreviewContentPolicy.content(forFiles: urls)
        }
    }
}
