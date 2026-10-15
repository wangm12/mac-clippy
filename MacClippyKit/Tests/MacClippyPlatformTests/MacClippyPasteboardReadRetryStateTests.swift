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

    func testDeprecatedUpdateUnavailableTypesMatchesGenerationAwareUpdate() throws {
        let original = PasteboardChange(
            changeCount: 42,
            items: [PasteboardItem(types: ["public.utf8-plain-text", "com.lazy"], representations: [
                "public.utf8-plain-text": Data("ready".utf8)
            ])],
            sourceAppBundleID: "com.example.source"
        )
        let remaining = [(itemIndex: 0, uti: "com.lazy")]

        let compatibilityState = MacClippyPasteboardReadRetryState(maxAttempts: 4)
        compatibilityState.record(change: original, unavailableTypes: [(0, "com.lazy"), (0, "com.other")])
        XCTAssertTrue(compatibilityState.incrementAttempts(for: 42))

        let primaryState = MacClippyPasteboardReadRetryState(maxAttempts: 4)
        primaryState.record(change: original, unavailableTypes: [(0, "com.lazy"), (0, "com.other")])
        XCTAssertTrue(primaryState.incrementAttempts(for: 42))
        XCTAssertTrue(primaryState.update(change: original, unavailableTypes: remaining))

        compatibilityState.updateUnavailableTypes(for: 42, unavailableTypes: remaining)

        let compatibilityPending = try XCTUnwrap(compatibilityState.pending(for: 42))
        let primaryPending = try XCTUnwrap(primaryState.pending(for: 42))
        XCTAssertEqual(compatibilityPending.attempts, primaryPending.attempts)
        XCTAssertEqual(compatibilityPending.unavailableTypes.map(\.uti), primaryPending.unavailableTypes.map(\.uti))
        XCTAssertEqual(
            compatibilityPending.unavailableTypes.map(\.itemIndex),
            primaryPending.unavailableTypes.map(\.itemIndex)
        )
        XCTAssertEqual(compatibilityPending.originalChange, primaryPending.originalChange)
    }

    func testDeprecatedUpdateUnavailableTypesPreservesLegacyCountOnlyBehavior() throws {
        let state = MacClippyPasteboardReadRetryState(maxAttempts: 4)
        state.record(changeCount: 70, unavailableTypes: [(0, "a"), (1, "b")])
        XCTAssertTrue(state.incrementAttempts(for: 70))

        state.updateUnavailableTypes(for: 70, unavailableTypes: [(1, "b")])

        let pending = try XCTUnwrap(state.pending(for: 70))
        XCTAssertNil(pending.originalChange)
        XCTAssertEqual(pending.attempts, 1)
        XCTAssertEqual(pending.unavailableTypes.map(\.uti), ["b"])
        XCTAssertEqual(pending.unavailableTypes.map(\.itemIndex), [1])

        state.updateUnavailableTypes(for: 70, unavailableTypes: [])
        XCTAssertNil(state.pending(for: 70), "an empty legacy update clears the pending entry")
        state.updateUnavailableTypes(for: 71, unavailableTypes: [(0, "unknown")])
        XCTAssertNil(state.pending(for: 71), "unknown generations remain a no-op")
    }

    func testRetryUpdateStillRequiresMatchingGenerationAndItemTypes() throws {
        let original = PasteboardChange(
            changeCount: 51,
            items: [PasteboardItem(types: ["public.utf8-plain-text", "com.lazy"], representations: [
                "public.utf8-plain-text": Data("ready".utf8)
            ])]
        )
        let differentTypes = PasteboardChange(
            changeCount: 51,
            items: [PasteboardItem(types: ["public.utf8-plain-text", "com.other"], representations: [
                "public.utf8-plain-text": Data("ready".utf8)
            ])]
        )
        let state = MacClippyPasteboardReadRetryState()
        state.record(change: original, unavailableTypes: [(0, "com.lazy")])

        XCTAssertFalse(state.update(change: differentTypes, unavailableTypes: [(0, "com.other")]))
        state.updateUnavailableTypes(for: 52, unavailableTypes: [(0, "com.lazy")])

        let pending = try XCTUnwrap(state.pending(for: 51))
        XCTAssertEqual(pending.originalChange, original)
        XCTAssertEqual(pending.unavailableTypes.map(\.uti), ["com.lazy"])
        XCTAssertNil(state.pending(for: 52))
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
