import AppKit
import Foundation
import MacClippyPlatform
import QuartzCore
import SwiftUI

extension MacClippyDockController {
    func showCopyToast(title: String) {
        let screen = screenContainingCursor() ?? NSScreen.main
        guard let screen else { return }

        let toastView = MacClippyCopyToastView(title: title)
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
        toast.contentView?.layer?.opacity = 0
        toast.orderFrontRegardless()
        announceCopyToast(title)
        animateToastOpacity(toast, from: 0, to: 1, duration: MacClippyMotion.actionFeedbackDuration)

        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.dismissCopyToast()
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
        guard let toast = toastPanel, toast.isVisible else { return }
        animateToastOpacity(toast, from: toast.contentView?.layer?.opacity ?? 1, to: 0, duration: 0.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak toast] in
            guard let self, self.toastPanel === toast else { return }
            toast?.orderOut(nil)
        }
    }

    private func animateToastOpacity(
        _ toast: NSWindow,
        from: Float,
        to: Float,
        duration: TimeInterval
    ) {
        guard let layer = toast.contentView?.layer else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = MacClippyMotion.entranceTimingFunction
        layer.add(animation, forKey: "macClippyToastOpacity")
        layer.opacity = to
    }
}
