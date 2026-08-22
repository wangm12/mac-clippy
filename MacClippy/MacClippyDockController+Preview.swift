import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import QuartzCore
import QuickLookUI
import SwiftUI
import os.signpost

extension MacClippyDockController: MacClippySystemQuickLookHosting {
    func showPreview() {
        if interactionMode == .details {
            guard hideDetails() else { return }
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
        cancelPreviewRetry()

        previewRequestID &+= 1
        dockPanel.interceptsPickerKeys = true
        interactionMode = .preview
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

    func refreshPreview() {
        guard interactionMode == .preview,
              let target = model.focusedPreviewTarget else { return }
        previewRequestID &+= 1
        presentPreview(for: target, requestID: previewRequestID, isOpening: false)
    }

    func presentPreview(
        for target: MacClippyDockPreviewTarget,
        requestID: UInt,
        isOpening: Bool
    ) {
        let transition = MacClippyPreviewSurfacePolicy.transition(isOpening: isOpening)
        if case .item = target,
           let item = model.focusedItem,
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
            preview.setFrame(
                previewFrame.offsetBy(dx: 0, dy: -MacClippyMotion.panelOffset),
                display: false,
                animate: false
            )
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MacClippyMotion.entranceDuration
                context.timingFunction = MacClippyMotion.entranceTimingFunction
                preview.animator().setFrame(previewFrame, display: true)
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
                  self.model.focusedPreviewTarget == target,
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

    // The single helper that moves model focus and refreshes the preview. Both
    // the keyboard arrows and the preview header's prev/next chevrons route
    // through here so the focused card highlight and the preview content stay
    // in sync. Wraparound is preserved by model.moveFocus(by:).

    func moveFocusedPreview(direction: MacClippyDockSelectionDirection) {
        model.moveFocus(direction)
        if interactionMode == .details {
            refreshDetails()
        } else {
            refreshPreview()
        }
    }

    func refreshDetails() {
        guard interactionMode == .details,
              let target = model.focusedItem else { return }
        let targetID = target.id
        detailsRequestID &+= 1
        let requestID = detailsRequestID
        details = nil
        detailsEditing = .none
        setDetailsRootView(AnyView(MacClippyDetailsLoadingView()))
        model.loadDetails(for: targetID) { [weak self] result in
            guard let self,
                  self.detailsRequestID == requestID,
                  self.interactionMode == .details,
                  self.model.focusedItem?.id == targetID else { return }
            switch result {
            case let .success(details):
                self.details = details
                self.detailsEditing = .none
                self.setDetailsRootView(AnyView(self.detailsView(details: details, editing: .none)))
            case .failure:
                self.details = nil
                self.detailsEditing = .none
                self.setDetailsRootView(AnyView(MacClippyDetailsErrorView(
                    message: MacClippyUserFacingError.itemLoad,
                    onRetry: { [weak self] in self?.refreshDetails() },
                    onClose: { [weak self] in self?.hideDetails() }
                )))
            }
        }
    }

    // Builds the preview SwiftUI view for a content case, wiring the prev/next
    // navigation callback and the metadata (source icon/name/time/char count)
    // from the focused item. Centralized so the show, refresh, and error paths
    // share the same callback wiring and metadata.

    func previewView(content: MacClippyDockPreviewContent) -> MacClippyDockPreviewView {
        let meta = previewMetadata()
        return MacClippyDockPreviewView(
            content: content,
            metadata: meta,
            reduceMotion: shouldReduceMotion,
            onNavigate: { [weak self] direction in
                self?.moveFocusedPreview(direction: direction == .previous ? .left : .right)
            },
            onCopy: { [weak self] in
                self?.model.copyFocused()
            },
            recognizeOCRLayout: model.runtime.recognizeOCRLayout,
            onCopyText: { [weak self] text in
                self?.copyPreviewText(text)
            },
            onDismiss: { [weak self] in
                self?.hidePreview()
            }
        )
    }

    // Resolve QuickLook-style metadata from the focused item: source app
    // presentation, relative timestamp, and character count of the preview.

    func previewMetadata() -> MacClippyDockPreviewMetadata {
        guard let item = model.focusedItem else { return .unknown }
        let source = MacClippySourceAppResolver.presentation(for: item.meta.sourceAppBundleID)
        let time = MacClippyDockTimestampPolicy.relativeLabel(for: item.meta.modified)
        let chars = item.preview.count
        return MacClippyDockPreviewMetadata(
            sourceName: source.displayName,
            sourceIcon: source.icon,
            sourceAccent: source.accent,
            relativeTime: time,
            characterCount: chars,
            ocrText: item.meta.ocrText
        )
    }

    func copyPreviewText(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        do {
            try model.runtime.pasteInjector.prepareTextForHistory(normalized)
            showCopyToast(title: "Text copied")
        } catch {
            model.setActionError(MacClippyUserFacingError.message(for: error))
        }
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
        let targetFrame = preview.frame.offsetBy(dx: 0, dy: -MacClippyMotion.panelOffset)
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
                preview.animator().setFrame(targetFrame, display: true)
                preview.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in finish() }
            })
        }
    }

    private func finishPreviewPerformance(signpostID: OSSignpostID?) {
        guard let signpostID, previewPerformanceSignpostID == signpostID else { return }
        MacClippyPerformance.end("preview_open", id: signpostID)
        previewPerformanceSignpostID = nil
    }

    func dismissPreviewImmediately() {
        cancelPreviewRetry()
        previewRequestID &+= 1
        previewAnimationGeneration &+= 1
        previewIsClosing = false
        closeSystemQuickLook(animated: false)
        interactionMode = .picker
        model.isPreviewVisible = false
        previewPanel?.contentView?.layer?.removeAllAnimations()
        previewPanel?.orderOut(nil)
        previewPanel?.close()
        previewPanel = nil
        previewHostingView = nil
    }

    func resetPreviewPanelState(_ preview: NSWindow) {
        preview.contentView?.layer?.removeAllAnimations()
        preview.alphaValue = 1
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
