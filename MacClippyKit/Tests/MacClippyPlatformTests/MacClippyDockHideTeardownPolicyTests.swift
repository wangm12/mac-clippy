import XCTest

@testable import MacClippyPlatform

final class MacClippyDockHideTeardownPolicyTests: XCTestCase {
    func testOutsideClickDoesNotClearThumbnailsBeforeThePanelIsGone() {
        XCTAssertFalse(
            MacClippyDockHideTeardownPolicy.shouldResetThumbnailCachesBeforeHideAnimation()
        )
    }

    func testOutsideClickDoesNotWaitForTheNextMainActorTurn() {
        XCTAssertFalse(
            MacClippyDockHideTeardownPolicy.shouldDeferOutsideClickToNextMainActorTurn()
        )
    }
}
