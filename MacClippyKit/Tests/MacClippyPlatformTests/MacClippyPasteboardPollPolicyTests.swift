import XCTest

@testable import MacClippyPlatform

final class MacClippyPasteboardPollPolicyTests: XCTestCase {
    func testForegroundIntervalStaysInTheFiftyToHundredMillisecondBand() {
        let interval = MacClippyPasteboardPollPolicy.pollInterval(for: .foreground)
        XCTAssertGreaterThanOrEqual(interval, 0.05)
        XCTAssertLessThanOrEqual(interval, 0.10)
    }

    func testBackgroundIntervalStaysInTheThreeToFiveHundredMillisecondBand() {
        let interval = MacClippyPasteboardPollPolicy.pollInterval(for: .background)
        XCTAssertGreaterThanOrEqual(interval, 0.30)
        XCTAssertLessThanOrEqual(interval, 0.50)
    }

    func testActivityFollowsUserInputAndRecentCopiesNotAppActivation() {
        XCTAssertEqual(
            MacClippyPasteboardPollPolicy.activity(
                secondsSinceLastUserInput: 1,
                secondsSinceLastObservedChange: nil
            ),
            .foreground
        )
        XCTAssertEqual(
            MacClippyPasteboardPollPolicy.activity(
                secondsSinceLastUserInput: 120,
                secondsSinceLastObservedChange: nil
            ),
            .background
        )
        XCTAssertEqual(
            MacClippyPasteboardPollPolicy.activity(
                secondsSinceLastUserInput: 120,
                secondsSinceLastObservedChange: 0.4
            ),
            .foreground
        )
        XCTAssertEqual(
            MacClippyPasteboardPollPolicy.activity(
                secondsSinceLastUserInput: 120,
                secondsSinceLastObservedChange: 10
            ),
            .background
        )
    }
}
