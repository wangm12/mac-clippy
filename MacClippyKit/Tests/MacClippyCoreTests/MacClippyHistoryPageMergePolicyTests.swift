import XCTest

@testable import MacClippyCore

final class MacClippyHistoryPageMergePolicyTests: XCTestCase {
    func testEmptyExistingListAppendsTheIncomingPage() {
        XCTAssertTrue(
            MacClippyHistoryPageMergePolicy.shouldAppendOlderPage(
                existingOldest: nil,
                additionsNewest: key(modified: 1, lamport: 1, id: "a")
            )
        )
    }

    func testOlderPageAppendsWithoutAFullResort() {
        XCTAssertTrue(
            MacClippyHistoryPageMergePolicy.shouldAppendOlderPage(
                existingOldest: key(modified: 20, lamport: 2, id: "b"),
                additionsNewest: key(modified: 10, lamport: 1, id: "c")
            )
        )
    }

    func testEqualOldestBoundaryStillAppends() {
        let boundary = key(modified: 10, lamport: 4, id: "same")
        XCTAssertTrue(
            MacClippyHistoryPageMergePolicy.shouldAppendOlderPage(
                existingOldest: boundary,
                additionsNewest: boundary
            )
        )
    }

    func testNewerThanTheTailRequiresAFullSort() {
        XCTAssertFalse(
            MacClippyHistoryPageMergePolicy.shouldAppendOlderPage(
                existingOldest: key(modified: 10, lamport: 1, id: "old"),
                additionsNewest: key(modified: 30, lamport: 9, id: "new")
            )
        )
    }

    func testLamportBreaksModifiedTiesInRecencyOrder() {
        XCTAssertTrue(
            MacClippyHistoryPageMergePolicy.isMoreRecent(
                key(modified: 10, lamport: 8, id: "a"),
                than: key(modified: 10, lamport: 2, id: "b")
            )
        )
        XCTAssertTrue(
            MacClippyHistoryPageMergePolicy.isMoreRecent(
                key(modified: 10, lamport: 2, id: "z"),
                than: key(modified: 10, lamport: 2, id: "a")
            )
        )
    }

    private func key(modified: TimeInterval, lamport: UInt64, id: String) -> MacClippyHistoryRecencyKey {
        MacClippyHistoryRecencyKey(
            modified: Date(timeIntervalSince1970: modified),
            lamport: lamport,
            id: id
        )
    }
}
