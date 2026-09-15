import Foundation

public struct MacClippyPanelOpacityRamp: Equatable, Sendable {
    public let from: Float
    public let to: Float

    public init(from: Float, to: Float) {
        self.from = from
        self.to = to
    }
}

/// Regular glass re-samples the desktop every frame. Keep the window frame
/// still, fade the foreground, and scale the layer. Never fade the backdrop.
public enum MacClippyPanelGlassMotionPolicy {
    public static func shouldFadeBackdrop() -> Bool {
        false
    }

    public static func shouldAnimateWindowFrame() -> Bool {
        false
    }

    public static func backdropOpacity(animated _: Bool) -> MacClippyPanelOpacityRamp {
        MacClippyPanelOpacityRamp(from: 1, to: 1)
    }

    public static func shouldSkipAnimatedTransition(
        reduceMotion: Bool,
        skipGlassMotion: Bool,
        hideReason: MacClippyDockHideReason = .command
    ) -> Bool {
        return reduceMotion || skipGlassMotion || hideReason == .outsideClick || hideReason == .spaceChange
    }
}
