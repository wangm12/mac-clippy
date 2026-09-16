import AppKit
import QuartzCore
import XCTest

@testable import MacClippy

enum MacClippyTestWait {
    /// Drain dock/runtime completions without leaving leftover window
    /// animations on the default run loop.
    ///
    /// Background pasteboard work can `dispatch_sync` onto main, so this still
    /// pumps the run loop. It first disables window animations because the
    /// MacClippy test host crashes in `_NSWindowTransformAnimation` dealloc
    /// after earlier tests have ordered panels on screen.
    ///
    /// Does not fail on timeout: several tests use `wait` only to let a stale
    /// completion drain, then assert that nothing happened.
    static func until(
        _ condition: () -> Bool,
        timeout: TimeInterval = 2.0,
        failOnTimeout: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        MacClippyMainHop.setCaptureForTesting(true)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            MacClippyMainHop.flushCapturedWork()
            if condition() {
                Thread.sleep(forTimeInterval: 0.01)
                MacClippyMainHop.flushCapturedWork()
                return
            }
            neutralizeWindowAnimations()
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
            MacClippyMainHop.flushCapturedWork()
        }
        MacClippyMainHop.flushCapturedWork()
        if failOnTimeout, !condition() {
            XCTFail("Timed out waiting for condition", file: file, line: line)
        }
    }

    private static func neutralizeWindowAnimations() {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            NSAnimationContext.current.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for window in NSApp.windows {
                window.animationBehavior = .none
                window.animations = [:]
                window.contentView?.layer?.removeAllAnimations()
            }
            CATransaction.commit()
            CATransaction.flush()
            NSAnimationContext.endGrouping()
        }
    }
}
