import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import QuartzCore
import QuickLookUI
import SwiftUI
import os.signpost

extension MacClippyDockController {
    func finishPreviewPerformance(signpostID: OSSignpostID?) {
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

}
