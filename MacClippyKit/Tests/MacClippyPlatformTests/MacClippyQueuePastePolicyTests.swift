import XCTest

import MacClippyPlatform

// Focused test for the queue-paste settle policy. The policy only names the
// settle interval waited between successful paste injections; the value is
// asserted here so a future change is intentional and not a silent regression
// that either starves the target app (too short) or makes the queue feel
// sluggish (too long).
final class MacClippyQueuePastePolicyTests: XCTestCase {
    func testSettleIntervalIsPositiveAndBounded() {
        let interval = MacClippyQueuePastePolicy.settleInterval
        XCTAssertGreaterThan(interval, 0, "settle interval must be positive so the target app can consume each paste")
        XCTAssertLessThanOrEqual(interval, 1.0, "settle interval must stay small so a multi-record queue does not feel slow")
    }
}
