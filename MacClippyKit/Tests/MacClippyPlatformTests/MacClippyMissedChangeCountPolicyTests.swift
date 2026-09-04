import XCTest

@testable import MacClippyPlatform

final class MacClippyMissedChangeCountPolicyTests: XCTestCase {
    func testSingleStepAdvanceIsJustTheObservedCount() {
        XCTAssertEqual(
            MacClippyMissedChangeCountPolicy.catchUpChangeCounts(after: 5, observed: 6),
            [6]
        )
        XCTAssertFalse(MacClippyMissedChangeCountPolicy.hasMissedGenerations(after: 5, observed: 6))
    }

    func testJumpIncludesEveryIntermediateGenerationOldestFirst() {
        XCTAssertEqual(
            MacClippyMissedChangeCountPolicy.catchUpChangeCounts(after: 5, observed: 8),
            [6, 7, 8]
        )
        XCTAssertTrue(MacClippyMissedChangeCountPolicy.hasMissedGenerations(after: 5, observed: 8))
    }

    func testUnchangedOrBackwardCountsAreNotCaughtUp() {
        XCTAssertEqual(
            MacClippyMissedChangeCountPolicy.catchUpChangeCounts(after: 5, observed: 5),
            []
        )
        XCTAssertEqual(
            MacClippyMissedChangeCountPolicy.catchUpChangeCounts(after: 5, observed: 4),
            []
        )
        XCTAssertFalse(MacClippyMissedChangeCountPolicy.hasMissedGenerations(after: 5, observed: 5))
    }

    func testOversizedJumpKeepsTheMostRecentCountsIncludingLatest() {
        XCTAssertEqual(
            MacClippyMissedChangeCountPolicy.catchUpChangeCounts(
                after: 1,
                observed: 100,
                limit: 8
            ),
            Array(93...100)
        )
    }
}
