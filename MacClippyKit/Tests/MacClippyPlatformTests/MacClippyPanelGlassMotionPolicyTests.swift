import XCTest

@testable import MacClippyPlatform

final class MacClippyPanelGlassMotionPolicyTests: XCTestCase {
    func testBackdropStaysOpaqueAndTheWindowFrameDoesNotSlide() {
        XCTAssertFalse(MacClippyPanelGlassMotionPolicy.shouldAnimateWindowFrame())
        XCTAssertFalse(MacClippyPanelGlassMotionPolicy.shouldFadeBackdrop())
        XCTAssertEqual(
            MacClippyPanelGlassMotionPolicy.backdropOpacity(animated: true),
            MacClippyPanelOpacityRamp(from: 1, to: 1)
        )
        XCTAssertEqual(
            MacClippyPanelGlassMotionPolicy.backdropOpacity(animated: false),
            MacClippyPanelOpacityRamp(from: 1, to: 1)
        )
    }

    func testHideSkipsMotionWhenDisplayChurnAskedToSkipGlass() {
        XCTAssertTrue(
            MacClippyPanelGlassMotionPolicy.shouldSkipAnimatedTransition(
                reduceMotion: false,
                skipGlassMotion: true
            )
        )
        XCTAssertTrue(
            MacClippyPanelGlassMotionPolicy.shouldSkipAnimatedTransition(
                reduceMotion: true,
                skipGlassMotion: false
            )
        )
        XCTAssertFalse(
            MacClippyPanelGlassMotionPolicy.shouldSkipAnimatedTransition(
                reduceMotion: false,
                skipGlassMotion: false
            )
        )
        XCTAssertFalse(
            MacClippyPanelGlassMotionPolicy.shouldSkipAnimatedTransition(
                reduceMotion: false,
                skipGlassMotion: false,
                hideReason: .command
            )
        )
        XCTAssertTrue(
            MacClippyPanelGlassMotionPolicy.shouldSkipAnimatedTransition(
                reduceMotion: false,
                skipGlassMotion: false,
                hideReason: .outsideClick
            )
        )
    }
}
