import XCTest

import MacClippyPlatform

final class MacClippyFileIconWaiterAccountingTests: XCTestCase {
    func testReleasingTheLastWaiterCancelsUnfinishedWork() {
        let state = MacClippyFileIconWaiterAccounting()
        state.addWaiter()
        state.addWaiter()
        XCTAssertFalse(state.releaseWaiter())
        XCTAssertTrue(state.releaseWaiter())
        XCTAssertFalse(state.isFinished)
    }

    func testFinishedWorkIsNotCancelledWhenTheLastWaiterLeaves() {
        let state = MacClippyFileIconWaiterAccounting()
        state.addWaiter()
        state.markFinished()
        XCTAssertTrue(state.isFinished)
        XCTAssertFalse(state.releaseWaiter())
    }
}
