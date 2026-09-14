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

    /// All after URL/Image/Snippets can leave `historyItems` on a filtered
    /// snapshot (including `[]` for Image-with-no-images). Returning to All
    /// with an empty query does not schedule a History reload by itself.
    static func shouldReloadHistoryForAllFilter(historyQuery: String, query: String) -> Bool {
        historyQuery != query
    }

    static func shouldReuseVisibleHistoryOnShow(
        queryIsEmpty: Bool,
        historyQueryIsEmpty: Bool,
        hasItems: Bool
    ) -> Bool {
        queryIsEmpty && historyQueryIsEmpty && hasItems
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
    private var pendingWork: (@MainActor () -> Void)?

    func schedule(_ work: @escaping @MainActor () -> Void) {
        guard !isScheduled else { return }
        isScheduled = true
        pendingWork = work
        MacClippyMainHop.async { [weak self] in
            self?.performPendingWork()
        }
    }

    func performPendingWork() {
        guard isScheduled, let work = pendingWork else { return }
        pendingWork = nil
        isScheduled = false
        work()
    }
}
