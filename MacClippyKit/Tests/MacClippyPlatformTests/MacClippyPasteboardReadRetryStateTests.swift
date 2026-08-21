import AppKit
import Foundation
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class MacClippyPasteboardReadRetryStateTests: XCTestCase {
    func testRecordSeedsPendingAndClearRemovesIt() {
        let state = MacClippyPasteboardReadRetryState(maxAttempts: 3)
        XCTAssertFalse(state.hasPending)

        state.record(changeCount: 5, unavailableTypes: [(0, "com.lazy")])
        XCTAssertTrue(state.hasPending)
        XCTAssertEqual(state.pending(for: 5)?.unavailableTypes.map { $0.uti }, ["com.lazy"])
        XCTAssertEqual(state.pending(for: 5)?.unavailableTypes.map { $0.itemIndex }, [0])
        XCTAssertEqual(state.pending(for: 5)?.attempts, 0)

        state.clear(changeCount: 5)
        XCTAssertFalse(state.hasPending)
        XCTAssertNil(state.pending(for: 5))
    }

    func testRecordWithEmptyUnavailableListDoesNotCreatePending() {
        let state = MacClippyPasteboardReadRetryState()
        state.record(changeCount: 7, unavailableTypes: [])
        XCTAssertFalse(state.hasPending)
        XCTAssertNil(state.pending(for: 7))
    }

    func testIncrementAttemptsReturnsTrueUntilBudgetExhausted() {
        let state = MacClippyPasteboardReadRetryState(maxAttempts: 3)
        state.record(changeCount: 9, unavailableTypes: [(0, "a"), (1, "b")])

        XCTAssertTrue(state.incrementAttempts(for: 9)) // attempts 1 < 3
        XCTAssertTrue(state.incrementAttempts(for: 9)) // attempts 2 < 3
        XCTAssertFalse(state.incrementAttempts(for: 9)) // attempts 3, budget exhausted
        XCTAssertEqual(state.pending(for: 9)?.attempts, 3)
    }

    func testIncrementAttemptsForUnknownChangeCountReturnsFalse() {
        let state = MacClippyPasteboardReadRetryState()
        XCTAssertFalse(state.incrementAttempts(for: 123))
    }

    func testClearAllDropsEveryPendingEntry() {
        // stop()/restart on the observer clears all cross-poll retry state so
        // a new session cannot inherit stale pending entries from the prior
        // session. clearAll() must drop every pending changeCount regardless
        // of how many were in flight.
        let state = MacClippyPasteboardReadRetryState(maxAttempts: 3)
        state.record(changeCount: 10, unavailableTypes: [(0, "com.lazy.a")])
        state.record(changeCount: 11, unavailableTypes: [(0, "com.lazy.b")])
        state.incrementAttempts(for: 10)
        XCTAssertTrue(state.hasPending)
        XCTAssertEqual(state.pendingChangeCount, 11)

        state.clearAll()

        XCTAssertFalse(state.hasPending)
        XCTAssertNil(state.pendingChangeCount)
        XCTAssertNil(state.pending(for: 10))
        XCTAssertNil(state.pending(for: 11))
    }

    func testUnavailableTypesDetectsAdvertisedButMissingPayloads() {
        let change = PasteboardChange(
            changeCount: 1,
            items: [
                PasteboardItem(types: ["public.utf8-plain-text", "com.missing"], representations: [
                    "public.utf8-plain-text": Data("kept".utf8)
                    // com.missing advertised but absent
                ]),
                PasteboardItem(types: ["com.also-missing"], representations: [:])
            ]
        )

        let unavailable = MacClippyPasteboardAvailability.unavailableTypes(in: change)

        XCTAssertEqual(unavailable.count, 2)
        XCTAssertEqual(unavailable[0].itemIndex, 0)
        XCTAssertEqual(unavailable[0].uti, "com.missing")
        XCTAssertEqual(unavailable[1].itemIndex, 1)
        XCTAssertEqual(unavailable[1].uti, "com.also-missing")
    }

    func testUnavailableTypesTreatsEmptyPayloadAsAvailable() {
        // An empty Data payload is NOT unavailable; it is a present, zero-byte
        // payload. Only advertised types with no payload at all are unavailable.
        let change = PasteboardChange(
            changeCount: 1,
            items: [PasteboardItem(types: ["com.empty", "com.missing"], representations: [
                "com.empty": Data()
            ])]
        )

        let unavailable = MacClippyPasteboardAvailability.unavailableTypes(in: change)

        XCTAssertEqual(unavailable.count, 1)
        XCTAssertEqual(unavailable[0].itemIndex, 0)
        XCTAssertEqual(unavailable[0].uti, "com.missing")
    }
}
