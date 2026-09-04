import XCTest

@testable import MacClippyPlatform

final class MacClippyDisplayGenerationPolicyTests: XCTestCase {
    func testWakeDiscardsAHiddenPanelAndRecreatesTheStatusItem() {
        XCTAssertTrue(
            MacClippyDisplayGenerationPolicy.shouldDiscardHiddenPanel(
                event: .didWake,
                panelExists: true,
                isVisible: false
            )
        )
        XCTAssertTrue(MacClippyDisplayGenerationPolicy.shouldRecreateStatusItem(for: .didWake))
        XCTAssertTrue(MacClippyDisplayGenerationPolicy.shouldSkipGlassMotion(pendingEvent: .didWake))
    }

    func testScreenParameterChangeDiscardsHiddenPanelEvenWhenItWasNeverShownAsVisible() {
        XCTAssertTrue(
            MacClippyDisplayGenerationPolicy.shouldDiscardHiddenPanel(
                event: .screenParametersChanged,
                panelExists: true,
                isVisible: false
            )
        )
        XCTAssertFalse(
            MacClippyDisplayGenerationPolicy.shouldDiscardHiddenPanel(
                event: .screenParametersChanged,
                panelExists: false,
                isVisible: false
            )
        )
        XCTAssertFalse(
            MacClippyDisplayGenerationPolicy.shouldDiscardHiddenPanel(
                event: .screenParametersChanged,
                panelExists: true,
                isVisible: true
            )
        )
        XCTAssertTrue(
            MacClippyDisplayGenerationPolicy.shouldRecreateStatusItem(for: .screenParametersChanged)
        )
    }

    func testSleepDoesNotDiscardAPanelButMarksSkipMotion() {
        XCTAssertFalse(
            MacClippyDisplayGenerationPolicy.shouldDiscardHiddenPanel(
                event: .screensDidSleep,
                panelExists: true,
                isVisible: false
            )
        )
        XCTAssertFalse(MacClippyDisplayGenerationPolicy.shouldRecreateStatusItem(for: .screensDidSleep))
        XCTAssertFalse(
            MacClippyDisplayGenerationPolicy.shouldRebuildVisibleGlass(
                event: .screensDidSleep,
                isVisible: true
            )
        )
        XCTAssertTrue(MacClippyDisplayGenerationPolicy.shouldSkipGlassMotion(pendingEvent: .screensDidSleep))
    }

    func testWakeRebuildsVisibleGlassAndDoesNotRebuildWhenHidden() {
        XCTAssertTrue(
            MacClippyDisplayGenerationPolicy.shouldRebuildVisibleGlass(
                event: .didWake,
                isVisible: true
            )
        )
        XCTAssertFalse(
            MacClippyDisplayGenerationPolicy.shouldRebuildVisibleGlass(
                event: .didWake,
                isVisible: false
            )
        )
        XCTAssertTrue(
            MacClippyDisplayGenerationPolicy.shouldRebuildVisibleGlass(
                event: .screenParametersChanged,
                isVisible: true
            )
        )
        XCTAssertFalse(
            MacClippyDisplayGenerationPolicy.shouldRebuildVisibleGlass(
                event: .screenParametersChanged,
                isVisible: false
            )
        )
    }

    func testSkipMotionAppliesWhenPanelIsNil() {
        XCTAssertTrue(MacClippyDisplayGenerationPolicy.shouldSkipGlassMotion(pendingEvent: .didWake))
        XCTAssertFalse(MacClippyDisplayGenerationPolicy.shouldSkipGlassMotion(pendingEvent: nil))
    }

    func testSleepSuspendsPasteboardPollingAndWakeResumesIt() {
        XCTAssertEqual(
            MacClippyDisplayGenerationPolicy.shouldSuspendPasteboardPolling(for: .screensDidSleep),
            true
        )
        XCTAssertEqual(
            MacClippyDisplayGenerationPolicy.shouldSuspendPasteboardPolling(for: .didWake),
            false
        )
        XCTAssertEqual(
            MacClippyDisplayGenerationPolicy.shouldSuspendPasteboardPolling(for: .screensDidWake),
            false
        )
        XCTAssertNil(
            MacClippyDisplayGenerationPolicy.shouldSuspendPasteboardPolling(for: .screenParametersChanged)
        )
    }

    func testDisplayWakeRebuildsSurfacesLikeMachineWake() {
        XCTAssertTrue(
            MacClippyDisplayGenerationPolicy.shouldDiscardHiddenPanel(
                event: .screensDidWake,
                panelExists: true,
                isVisible: false
            )
        )
        XCTAssertTrue(MacClippyDisplayGenerationPolicy.shouldRecreateStatusItem(for: .screensDidWake))
        XCTAssertTrue(
            MacClippyDisplayGenerationPolicy.shouldRebuildVisibleGlass(
                event: .screensDidWake,
                isVisible: true
            )
        )
    }

    func testUnchangedScreensDoNotMarkTheSurfaceStale() {
        let previous = [
            CGRect(x: 0, y: 0, width: 2560, height: 1440),
            CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        ]
        XCTAssertFalse(
            MacClippyDisplayGenerationPolicy.shouldTreatAsDisplayChange(
                previousFrames: previous,
                currentFrames: previous
            )
        )
        XCTAssertTrue(
            MacClippyDisplayGenerationPolicy.shouldTreatAsDisplayChange(
                previousFrames: previous,
                currentFrames: [CGRect(x: 0, y: 0, width: 1512, height: 982)]
            )
        )
    }
}
