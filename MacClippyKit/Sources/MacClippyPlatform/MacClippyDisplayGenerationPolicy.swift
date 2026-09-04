import Foundation

public enum MacClippyDisplayLifecycleEvent: String, Sendable, Equatable {
    case screensDidSleep
    case screensDidWake
    case didWake
    case screenParametersChanged
}

public enum MacClippyDisplayGenerationPolicy {
    public static func shouldDiscardHiddenPanel(
        event: MacClippyDisplayLifecycleEvent,
        panelExists: Bool,
        isVisible: Bool
    ) -> Bool {
        guard panelExists, !isVisible else { return false }
        switch event {
        case .didWake, .screensDidWake, .screenParametersChanged:
            return true
        case .screensDidSleep:
            return false
        }
    }

    public static func shouldSkipGlassMotion(
        pendingEvent: MacClippyDisplayLifecycleEvent?
    ) -> Bool {
        pendingEvent != nil
    }

    public static func shouldRecreateStatusItem(
        for event: MacClippyDisplayLifecycleEvent
    ) -> Bool {
        switch event {
        case .didWake, .screensDidWake, .screenParametersChanged:
            return true
        case .screensDidSleep:
            return false
        }
    }

    public static func shouldRebuildVisibleGlass(
        event: MacClippyDisplayLifecycleEvent,
        isVisible: Bool
    ) -> Bool {
        guard isVisible else { return false }
        switch event {
        case .didWake, .screensDidWake, .screenParametersChanged:
            return true
        case .screensDidSleep:
            return false
        }
    }

    /// Sleep cancels the pasteboard timer. Wake arms it again. Screen-parameter
    /// changes keep the current polling state — they are not a sleep/wake edge.
    public static func shouldSuspendPasteboardPolling(
        for event: MacClippyDisplayLifecycleEvent
    ) -> Bool? {
        switch event {
        case .screensDidSleep:
            return true
        case .didWake, .screensDidWake:
            return false
        case .screenParametersChanged:
            return nil
        }
    }

    public static func shouldTreatAsDisplayChange(
        previousFrames: [CGRect],
        currentFrames: [CGRect]
    ) -> Bool {
        normalizedFrames(previousFrames) != normalizedFrames(currentFrames)
    }

    private static func normalizedFrames(_ frames: [CGRect]) -> [CGRect] {
        frames.sorted { lhs, rhs in
            if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
            if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
            if lhs.width != rhs.width { return lhs.width < rhs.width }
            return lhs.height < rhs.height
        }
    }
}
