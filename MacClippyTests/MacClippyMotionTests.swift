import XCTest

@testable import MacClippy

final class MacClippyMotionTests: XCTestCase {
    func testReduceMotionUsesEitherAccessibilitySource() {
        XCTAssertFalse(MacClippyMotion.shouldReduceMotion(swiftUI: false, appKit: false))
        XCTAssertTrue(MacClippyMotion.shouldReduceMotion(swiftUI: true, appKit: false))
        XCTAssertTrue(MacClippyMotion.shouldReduceMotion(swiftUI: false, appKit: true))
        XCTAssertTrue(MacClippyMotion.shouldReduceMotion(swiftUI: true, appKit: true))
    }

    func testMotionDurationsStayShortAndExitIsQuickerThanEntrance() {
        // Reference-aligned: dock enter ~180ms, exit ~130ms, hover/selection
        // ~120-140ms. Keep exit strictly quicker than entrance and the
        // content/focus durations in the reference hover/selection band.
        XCTAssertGreaterThanOrEqual(MacClippyMotion.entranceDuration, 0.16)
        XCTAssertLessThanOrEqual(MacClippyMotion.entranceDuration, 0.20)
        XCTAssertLessThan(MacClippyMotion.exitDuration, MacClippyMotion.entranceDuration)
        XCTAssertLessThanOrEqual(MacClippyMotion.contentDuration, 0.16)
        XCTAssertLessThanOrEqual(MacClippyMotion.focusDuration, 0.14)
        XCTAssertEqual(MacClippyMotion.contentOffset, 8)
        XCTAssertEqual(MacClippyMotion.panelOffset, 16)
        XCTAssertGreaterThan(MacClippyMotion.panelTravelPadding, 0)
        XCTAssertEqual(MacClippyMotion.panelContentScaleStart, 0.98)
        XCTAssertLessThan(MacClippyMotion.panelShadowOpacityStart, MacClippyMotion.panelShadowOpacity)
    }

    func testHoverLeaveAlwaysAppliesEvenWhileAButtonIsDown() {
        XCTAssertTrue(MacClippyDockHoverPolicy.shouldApplyHover(true, pressedMouseButtons: 0))
        XCTAssertTrue(MacClippyDockHoverPolicy.shouldApplyHover(true, pressedMouseButtons: 1))
        XCTAssertTrue(MacClippyDockHoverPolicy.shouldApplyHover(false, pressedMouseButtons: 0))
        XCTAssertTrue(MacClippyDockHoverPolicy.shouldApplyHover(false, pressedMouseButtons: 1))
        XCTAssertFalse(MacClippyDockHoverPolicy.isHovering(.ended))
        XCTAssertTrue(MacClippyDockHoverPolicy.isHovering(.active(.zero)))
    }

    func testInteractiveEffectsStaySubtle() {
        XCTAssertEqual(MacClippyMotion.hoverScale, 1.02)
        XCTAssertEqual(MacClippyMotion.hoverDuration, 0.12)
        XCTAssertLessThanOrEqual(MacClippyMotion.hoverScale, 1.03)
        XCTAssertLessThan(MacClippyMotion.settingsRevealStep, MacClippyMotion.settingsRevealDuration)
        XCTAssertEqual(MacClippyDockCardHoverChrome.shadowOpacity(elevated: false, hovered: false), 0.08)
        XCTAssertEqual(MacClippyDockCardHoverChrome.shadowOpacity(elevated: false, hovered: true), 0.13)
        XCTAssertEqual(MacClippyDockCardHoverChrome.shadowOpacity(elevated: true, hovered: false), 0.16)
        XCTAssertEqual(MacClippyDockCardHoverChrome.shadowOpacity(elevated: true, hovered: true), 0.18)
        XCTAssertEqual(MacClippyDockCardHoverChrome.shadowRadius(elevated: false, hovered: false), 10)
        XCTAssertEqual(MacClippyDockCardHoverChrome.shadowY(elevated: false, hovered: true), 4)
        XCTAssertEqual(MacClippyDockCardHoverChrome.shadowY(elevated: true, hovered: true), 5)
    }

    func testPanelTravelPlacesEntirePanelBelowItsFinalBottomEdge() {
        let frame = CGRect(x: 0, y: 0, width: 1_000, height: 360)
        let offscreen = MacClippyMotion.offscreenPanelFrame(for: frame)

        XCTAssertEqual(offscreen.width, frame.width)
        XCTAssertEqual(offscreen.height, frame.height)
        XCTAssertEqual(offscreen.maxY, frame.minY - MacClippyMotion.panelTravelPadding)
    }

    func testStaleHideCompletionCannotApplyAfterReopen() {
        let hiding = MacClippyDockAnimationTransaction(generation: 1, operation: .hiding)
        let reopened = MacClippyDockAnimationTransaction(generation: 2, operation: .showing)

        XCTAssertTrue(MacClippyDockAnimationLifecyclePolicy.shouldApplyCompletion(for: hiding, current: hiding))
        XCTAssertFalse(MacClippyDockAnimationLifecyclePolicy.shouldApplyCompletion(for: hiding, current: reopened))
        XCTAssertFalse(MacClippyDockAnimationLifecyclePolicy.shouldApplyCompletion(for: hiding, current: nil))
    }

    func testHistoryCapacityMapsToPersistedAgeValuesAndSliderIndices() {
        let expected: [(MacClippyHistoryCapacity, Int, Double)] = [
            (.day, 1, 0),
            (.week, 7, 1),
            (.month, 30, 2),
            (.unlimited, 0, 3)
        ]

        for (capacity, days, index) in expected {
            XCTAssertEqual(capacity.maxAgeDays, days)
            XCTAssertEqual(capacity.index, index)
            XCTAssertEqual(MacClippyHistoryCapacity(maxAgeDays: days), capacity)
            XCTAssertEqual(MacClippyHistoryCapacity(index: index), capacity)
        }
    }

    func testUnsupportedHistoryCapacityUsesDeterministicNearestChoice() {
        XCTAssertEqual(MacClippyHistoryCapacity(maxAgeDays: 2), .day)
        XCTAssertEqual(MacClippyHistoryCapacity(maxAgeDays: 10), .week)
        XCTAssertEqual(MacClippyHistoryCapacity(maxAgeDays: 20), .month)
        XCTAssertEqual(MacClippyHistoryCapacity(maxAgeDays: -1), .unlimited)
        XCTAssertEqual(MacClippyHistoryCapacity(index: -1), .day)
        XCTAssertEqual(MacClippyHistoryCapacity(index: 99), .unlimited)
    }

    func testHistoryCapacityNormalizesLegacyPersistedAgeValues() {
        XCTAssertEqual(MacClippyHistoryCapacity(maxAgeDays: 10).maxAgeDays, 7)

        for days in [0, 1, 7, 30] {
            XCTAssertEqual(MacClippyHistoryCapacity(maxAgeDays: days).maxAgeDays, days)
        }
    }

}
