import Foundation

enum MacClippyDockSessionOpenPolicy {
    static func shouldAnimateCardList(
        hasCompletedInitialPaint: Bool,
        reduceMotion: Bool
    ) -> Bool {
        hasCompletedInitialPaint && !reduceMotion
    }

    static func shouldPublishLoading(hasVisibleSnapshot: Bool) -> Bool {
        !hasVisibleSnapshot
    }

    static func shouldScheduleReloadForQueryChange(isSessionActive: Bool) -> Bool {
        isSessionActive
    }
}

enum MacClippyDockShowDiagnostics {
    static func impact(
        panelExisted: Bool,
        isLoading: Bool,
        itemCount: Int,
        screenFrame: CGRect,
        reduceMotion: Bool,
        skipGlassMotion: Bool
    ) -> String {
        let screen = "\(Int(screenFrame.width.rounded()))x\(Int(screenFrame.height.rounded()))"
        return [
            "panel_existed=\(panelExisted)",
            "is_loading=\(isLoading)",
            "items=\(itemCount)",
            "screen=\(screen)",
            "reduce_motion=\(reduceMotion)",
            "skip_glass_motion=\(skipGlassMotion)"
        ].joined(separator: " ")
    }
}

@MainActor
final class MacClippyMainQueueCoalescer {
    private var isScheduled = false

    func schedule(_ work: @escaping @MainActor () -> Void) {
        guard !isScheduled else { return }
        isScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isScheduled = false
            work()
        }
    }
}
