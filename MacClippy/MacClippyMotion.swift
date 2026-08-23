import AppKit
import os.signpost
import SwiftUI

enum MacClippyPerformance {
    private static let log = OSLog(
        subsystem: "com.macallyouneed.macclippy",
        category: "ui-performance"
    )

    static func begin(_ operation: StaticString) -> OSSignpostID {
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: operation, signpostID: signpostID)
        return signpostID
    }

    static func end(_ operation: StaticString, id: OSSignpostID) {
        os_signpost(.end, log: log, name: operation, signpostID: id)
    }
}

enum MacClippyMotion {
    // Reference-aligned durations: dock enter ~180ms, exit ~130ms, hover/
    // selection ~120-140ms. All animations share the same easing family.
    static let entranceDuration: TimeInterval = 0.18
    static let exitDuration: TimeInterval = 0.13
    static let contentDuration: TimeInterval = 0.14
    static let focusDuration: TimeInterval = 0.13
    static let actionFeedbackDuration: TimeInterval = 0.12
    static let actionFeedbackLifetime: TimeInterval = 1.1
    static let dropConfirmationLifetime: TimeInterval = 0.6
    static let hoverScale: CGFloat = 1.02
    static let hoverDuration: TimeInterval = 0.12
    static let hoverAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: hoverDuration)
    static let settingsRevealDuration: TimeInterval = 0.22
    static let settingsRevealStep: TimeInterval = 0.035
    static let settingsRevealOffset: CGFloat = 8
    static let outsideClickGraceDuration: TimeInterval = entranceDuration
    static let panelOffset: CGFloat = 16
    static let panelTravelPadding: CGFloat = 24
    static let foregroundRevealDelay: TimeInterval = 0.02
    static let panelContentScaleStart: CGFloat = 0.98
    static let panelShadowOpacityStart: Float = 0.08
    static let panelShadowOpacity: Float = 0.28
    static let panelShadowRadius: CGFloat = 24
    static let panelShadowYOffset: CGFloat = -10
    static let contentOffset: CGFloat = 8

    static let entranceAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: entranceDuration)
    static let exitAnimation = Animation.timingCurve(0.64, 0, 0.78, 0, duration: exitDuration)
    static let contentAnimation = Animation.timingCurve(0.65, 0, 0.35, 1, duration: contentDuration)
    static let focusAnimation = Animation.timingCurve(0.65, 0, 0.35, 1, duration: focusDuration)
    static let actionFeedbackAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: actionFeedbackDuration)
    static let settingsRevealAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: settingsRevealDuration)

    // Action bar entrance/exit. Use the same non-bouncy ease-out family as the
    // dock and content transitions so selection feedback stays fast and never
    // overshoots the compact header. Exit is faster so it never lingers over
    // content.
    static let actionBarEnterSpring = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.18)
    static let actionBarExit = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.15)
    // Per-button stagger delay for the action bar buttons (left-to-right fade).
    static let actionBarStaggerStep: TimeInterval = 0.03
    static let actionBarStaggerDuration: TimeInterval = 0.22

    // Keep the public token name for existing callers, but use a short
    // critically-damped ease-out. Preview arrow navigation must feel immediate
    // without the overshoot that a low-damping spring can introduce.
    static let focusFollowSpring = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.16)

    static var systemReduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func shouldReduceMotion(swiftUI: Bool, appKit: Bool) -> Bool {
        swiftUI || appKit
    }

    static func shouldReduceMotion(swiftUI: Bool) -> Bool {
        shouldReduceMotion(swiftUI: swiftUI, appKit: systemReduceMotion)
    }

    static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static var entranceTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
    }

    static var exitTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.64, 0, 0.78, 0)
    }

    static func offscreenPanelFrame(for frame: CGRect) -> CGRect {
        frame.offsetBy(dx: 0, dy: -(frame.height + panelTravelPadding))
    }

    static func contentTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .opacity.combined(with: .offset(x: contentOffset))
    }

    static func fadeTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .opacity
    }

    static func headerTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity)
    }

    // Animated List-style card updates: content changes enter with a small
    // horizontal nudge and leave with a short fade. The offset is deliberately
    // smaller than the panel transition so list updates stay subordinate to
    // the user's search and copy actions.
    static func cardListTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: contentOffset)),
            removal: .opacity.combined(with: .scale(scale: 0.98))
        )
    }

    // Vertical number flip for the "N selected" counter. Old digit slides up
    // and fades out; new digit slides up from below and fades in. Direction
    // is fixed upward (count up is the common case); Reduce Motion is an
    // immediate state change with no transition.
    static func numberFlipTransition(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .identity }
        return .opacity.combined(with: .offset(y: 8))
    }
}

// A short, low-contrast section reveal for Settings. It keeps the page
// readable and native while giving the initial load the same confident rhythm
// as the dock. Reduce Motion keeps the final state and removes the offset.
struct MacClippySettingsReveal: ViewModifier {
    let index: Int
    let reduceMotion: Bool
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion || isVisible ? 1 : 0)
            .offset(y: reduceMotion || isVisible ? 0 : MacClippyMotion.settingsRevealOffset)
            .animation(
                reduceMotion
                    ? nil
                    : MacClippyMotion.settingsRevealAnimation
                        .delay(Double(index) * MacClippyMotion.settingsRevealStep),
                value: isVisible
            )
            .onAppear {
                isVisible = true
            }
    }
}
