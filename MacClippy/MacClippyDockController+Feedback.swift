import AppKit
import Foundation
import MacClippyPlatform
import QuartzCore
import SwiftUI

extension MacClippyDockController {
    func showCopyToast(title: String) {
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
        announceCopyToast(title)

        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.toastPanel?.orderOut(nil)
        }
    }

    private func announceCopyToast(_ title: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [.announcement: title]
        )
    }

    func dismissCopyToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        toastPanel?.orderOut(nil)
    }
}
