import XCTest

@testable import MacClippyCore

final class MacClippyCapturePausePolicyTests: XCTestCase {
    func testTimedPauseDurationsIncludeFiveMinutesAndOneHour() {
        XCTAssertEqual(MacClippyTimedPauseDuration.thirtySeconds.seconds, 30)
        XCTAssertEqual(MacClippyTimedPauseDuration.fiveMinutes.seconds, 5 * 60)
        XCTAssertEqual(MacClippyTimedPauseDuration.oneHour.seconds, 60 * 60)
        XCTAssertNil(MacClippyTimedPauseDuration.untilResumed.seconds)
    }

    func testPauseEndsAtTheRequestedTimeAndUntilResumedStaysOpen() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            MacClippyCapturePausePolicy.endDate(now: now, duration: .fiveMinutes),
            now.addingTimeInterval(5 * 60)
        )
        XCTAssertEqual(
            MacClippyCapturePausePolicy.endDate(now: now, duration: .untilResumed),
            Date.distantFuture
        )
        XCTAssertTrue(
            MacClippyCapturePausePolicy.isActive(
                now: now.addingTimeInterval(60),
                until: now.addingTimeInterval(5 * 60)
            )
        )
        XCTAssertFalse(
            MacClippyCapturePausePolicy.isActive(
                now: now.addingTimeInterval(6 * 60),
                until: now.addingTimeInterval(5 * 60)
            )
        )
    }

    func testIgnoreNextCopyConsumesOneChangeThenResumes() {
        XCTAssertEqual(
            MacClippyCapturePausePolicy.consumeIgnoreNext(0),
            MacClippyIgnoreNextCopyDecision(shouldIgnore: false, remaining: 0)
        )
        XCTAssertEqual(
            MacClippyCapturePausePolicy.consumeIgnoreNext(1),
            MacClippyIgnoreNextCopyDecision(shouldIgnore: true, remaining: 0)
        )
        XCTAssertEqual(
            MacClippyCapturePausePolicy.consumeIgnoreNext(2),
            MacClippyIgnoreNextCopyDecision(shouldIgnore: true, remaining: 1)
        )
    }
}
