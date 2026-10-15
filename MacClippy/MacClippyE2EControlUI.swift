#if MACCLIPPY_E2E
import AppKit
import Foundation
import QuartzCore
import MacClippyCore
import MacClippyPlatform

@MainActor
extension AppDelegate {
    func showE2EPanel(acceptedAt: UInt64, activateApplication: Bool = true) async -> MacClippyE2EControlResponse {
        guard let controller = dockController else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "dock-unavailable")
        }
        MacClippyE2EUIInteractionProbe.shared.start()
        if activateApplication { activateE2EForVisibleUI(controller) }
        controller.show()
        guard await waitForE2EPanel(controller) else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "panel-interactive-timeout")
        }
        let completed = DispatchTime.now().uptimeNanoseconds
        return MacClippyE2EControlResponse(
            isOK: true,
            visibleCount: controller.model.visibleItems.count,
            uiLatencyMilliseconds: Double(completed - acceptedAt) / 1_000_000,
            panelVisible: controller.panel?.isVisible == true
        )
    }

    func hideE2EPanel(acceptedAt: UInt64) async -> MacClippyE2EControlResponse {
        guard let controller = dockController else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "dock-unavailable")
        }
        controller.hide()
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while controller.panel?.isVisible == true,
              DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let completed = DispatchTime.now().uptimeNanoseconds
        return MacClippyE2EControlResponse(
            isOK: controller.panel?.isVisible != true,
            errorCode: controller.panel?.isVisible == true ? "panel-hide-timeout" : nil,
            uiLatencyMilliseconds: Double(completed - acceptedAt) / 1_000_000,
            panelVisible: controller.panel?.isVisible == true
        )
    }

    func searchE2EUI(
        _ request: MacClippyE2EControlRequest,
        acceptedAt: UInt64
    ) async -> MacClippyE2EControlResponse {
        guard let controller = dockController,
              let query = request.query,
              !query.isEmpty else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "search-query-required")
        }
        activateE2EForVisibleUI(controller)
        if controller.panel?.isVisible != true {
            controller.show()
        }
        guard await waitForE2EPanel(controller) else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "panel-interactive-timeout")
        }
        controller.enterSearchMode()
        guard await prepareE2EModelSearch(controller, query: query) else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "ui-search-transition-timeout")
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(max(1, min(request.timeoutSeconds ?? 30, 120)) * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if !controller.model.isLoading,
               controller.model.query == query,
               controller.model.historyQuery == query,
               controller.panel?.isVisible == true,
               controller.panel?.isKeyWindow == true {
                await flushE2EPanelRendering(controller)
                guard controller.model.historyQuery == query,
                      !controller.model.isLoading,
                      controller.panel?.isVisible == true,
                      controller.panel?.isKeyWindow == true,
                      controller.panel?.contentView?.window != nil else { continue }
                let completed = DispatchTime.now().uptimeNanoseconds
                let visibleItems = controller.model.visibleItems
                return MacClippyE2EControlResponse(
                    isOK: true,
                    matchedRecordIDs: visibleItems.map { $0.id.rawValue },
                    hitCount: visibleItems.count,
                    visibleCount: visibleItems.count,
                    elapsedMilliseconds: Double(completed - acceptedAt) / 1_000_000,
                    uiLatencyMilliseconds: Double(completed - acceptedAt) / 1_000_000,
                    panelVisible: true,
                    searchCompleted: true
                )
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return MacClippyE2EControlResponse(isOK: false, errorCode: "ui-search-timeout")
    }

    func runE2EPreviewLoop(
        _ request: MacClippyE2EControlRequest
    ) async -> MacClippyE2EControlResponse {
        guard let controller = dockController,
              let query = request.query,
              !query.isEmpty else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "preview-query-required")
        }
        activateE2EForVisibleUI(controller)
        if controller.panel?.isVisible != true {
            controller.show()
        }
        guard await waitForE2EPanel(controller) else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "panel-interactive-timeout")
        }
        controller.enterSearchMode()
        guard await prepareE2EModelSearch(controller, query: query) else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "preview-item-search-timeout")
        }
        controller.setSearchMode(false)
        controller.model.ensureFocusedSelection()
        let cycleCount = min(max(request.cycles ?? 10, 1), 1_000)
        let started = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<cycleCount {
            controller.showPreview()
            guard await waitForE2EPreview(controller) else {
                return MacClippyE2EControlResponse(isOK: false, errorCode: "preview-render-timeout")
            }
            controller.hidePreview()
            guard await waitForE2EPreviewHidden(controller) else {
                return MacClippyE2EControlResponse(isOK: false, errorCode: "preview-close-timeout")
            }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - started
        return MacClippyE2EControlResponse(
            isOK: true,
            recordCount: cycleCount,
            elapsedMilliseconds: Double(elapsed) / 1_000_000,
            previewVisible: false,
            previewContentReady: true
        )
    }
    func activateE2EForVisibleUI(_ controller: MacClippyDockController) {
        controller.e2eFocusDiagnostic = { [weak e2eIsolation] detail in
            e2eIsolation?.recordDiagnostic(
                category: "native-focus", error: NSError(domain: detail, code: 0)
            )
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.pasteTargetApplication = NSRunningApplication.current
    }

    func waitForE2EPanel(_ controller: MacClippyDockController) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let panel = controller.panel,
               panel.isVisible,
               panel.isKeyWindow,
               !controller.model.isLoading,
               panel.contentView?.window != nil {
                // Reused mounted carousels need not emit another onAppear.
                // Measure the flushed visible surface, not its animation hint.
                await flushE2EPanelRendering(controller)
                let foregroundLayer = controller.panelContentView?.foregroundView.layer
                let visibleOpacity = foregroundLayer?.presentation()?.opacity
                    ?? foregroundLayer?.opacity
                    ?? 0
                if visibleOpacity >= 0.5 {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func waitForE2ESearch(
        _ controller: MacClippyDockController,
        query: String
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if controller.model.query == query,
               controller.model.historyQuery == query,
               !controller.model.isLoading,
               controller.panel?.isVisible == true,
               controller.panel?.isKeyWindow == true {
                await flushE2EPanelRendering(controller)
                return controller.panel?.isVisible == true
                    && controller.panel?.isKeyWindow == true
                    && controller.panel?.contentView?.window != nil
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func prepareE2EModelSearch(
        _ controller: MacClippyDockController,
        query: String
    ) async -> Bool {
        if controller.model.historyQuery == query,
           !controller.model.isLoading {
            let transitionQuery = query == "mce5oldneedle" ? "mce5commonneedle" : "mce5oldneedle"
            controller.model.replaceSearchQuery(transitionQuery)
            controller.model.reload()
            guard await waitForE2ESearch(controller, query: transitionQuery) else { return false }
        }
        controller.model.replaceSearchQuery(query)
        controller.model.reload()
        return await waitForE2ESearch(controller, query: query)
    }

    func waitForE2EPreview(_ controller: MacClippyDockController) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if controller.interactionMode == .preview,
               controller.previewPanel?.isVisible == true,
               (controller.previewPanel?.alphaValue ?? 0) >= 0.99,
               controller.previewPerformanceSignpostID == nil,
               controller.model.previewError == nil,
               isE2EPreviewContentReady(controller) {
                controller.previewPanel?.contentView?.layoutSubtreeIfNeeded()
                controller.previewPanel?.contentView?.displayIfNeeded()
                CATransaction.flush()
                await Task.yield()
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    private func isE2EPreviewContentReady(_ controller: MacClippyDockController) -> Bool {
        guard let content = controller.previewHostingView?.rootView.content else { return false }
        switch content {
        case .loading, .error:
            return false
        default:
            return true
        }
    }

    func waitForE2EPreviewHidden(_ controller: MacClippyDockController) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if controller.previewPanel?.isVisible != true,
               controller.interactionMode != .preview {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func flushE2EPanelRendering(_ controller: MacClippyDockController) async {
        controller.panel?.contentView?.layoutSubtreeIfNeeded()
        controller.panel?.contentView?.displayIfNeeded()
        CATransaction.flush()
        await Task.yield()
    }

}
#endif
