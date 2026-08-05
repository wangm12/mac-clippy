import AppKit
import Foundation
import XCTest

import MacClippyCore
import MacClippyPlatform

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

final class MacClippyPasteboardObserverRetryTests: XCTestCase {
    func testObserverWithholdsDeliveryUntilLazyPayloadArrivesAcrossPolls() {
        // A lazy provider advertises a UTI whose payload is unavailable on the
        // first poll for changeCount 2, then materializes it on a later poll.
        // The observer must withhold lastChangeCount advancement and delivery
        // until the payload arrives, then deliver the complete change.
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: ["public.utf8-plain-text": Data("seed".utf8)])
            ])
        )
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 1,
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 4)
        )
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }

        // First poll: changeCount 2 with the lazy UTI unavailable.
        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["public.utf8-plain-text", "com.lazy"], representations: [
                "public.utf8-plain-text": Data("hi".utf8)
                // com.lazy advertised but unavailable
            ])]
        )
        observer.poll()
        XCTAssertTrue(delivered.isEmpty, "must withhold delivery while lazy payload is pending")
        XCTAssertEqual(reader.readCount, 1, "the initial generation change should be the only full read before retry")

        // Second poll: same changeCount, still unavailable. Must keep waiting.
        observer.poll()
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(reader.readCount, 1, "cross-poll retry must not re-materialize available representations")

        // Third poll: the lazy provider materializes the bytes. The reader's
        // reread now returns the completed change.
        reader.rereadResult = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["public.utf8-plain-text", "com.lazy"], representations: [
                "public.utf8-plain-text": Data("hi".utf8),
                "com.lazy": Data("materialized".utf8)
            ])]
        )
        observer.poll()
        XCTAssertEqual(delivered.map { $0.changeCount }, [2])
        XCTAssertEqual(delivered.last?.items.first?.data(forType: "com.lazy"), Data("materialized".utf8))
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertEqual(reader.rereadCount, 2)

        observer.stop()
    }

    func testObserverDeliversUnavailableMarkersAfterRetryBudgetExhausted() {
        // The lazy provider never materializes the bytes. After the retry
        // budget is exhausted, the observer delivers the change so the
        // mapping layer can retain the advertised UTI as an .unavailable
        // marker instead of silently dropping the type.
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: ["public.utf8-plain-text": Data("seed".utf8)])
            ])
        )
        // rereadResult defaults to the same change (still unavailable).
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 1,
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 2)
        )
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }

        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["com.lazy"], representations: [:])]
        )
        // Poll 1: seed pending, spend attempt 1 (< 2) -> withhold.
        observer.poll()
        XCTAssertTrue(delivered.isEmpty)

        // Poll 2: reread (still unavailable), increment to attempt 2 == max -> budget exhausted -> deliver.
        observer.poll()
        XCTAssertEqual(delivered.map { $0.changeCount }, [2])

        // The delivered change still carries the advertised type with no
        // payload, so the mapping layer marks it .unavailable.
        let representations = MacClippyCaptureMapper.representations(for: delivered.last!)
        XCTAssertEqual(representations.map(\.uti), ["com.lazy"])
        XCTAssertEqual(representations.first?.payloadState, .unavailable)
        XCTAssertNil(representations.first?.payloadBytes)

        observer.stop()
    }

    func testObserverDeliversImmediatelyWhenNoUnavailableTypes() {
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: ["public.utf8-plain-text": Data("seed".utf8)])
            ])
        )
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 1,
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 4)
        )
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }

        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: ["public.utf8-plain-text": Data("ready".utf8)])]
        )
        observer.poll()
        XCTAssertEqual(delivered.map { $0.changeCount }, [2])

        observer.stop()
    }

    func testObserverNewChangeCountAbandonsPendingRetryForOlderChange() {
        // A new changeCount arrives while an older changeCount is still
        // pending retry. The observer must process the new changeCount and
        // not get stuck on the older pending entry.
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: ["public.utf8-plain-text": Data("seed".utf8)])
            ])
        )
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 1,
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 4)
        )
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }

        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["com.lazy"], representations: [:])]
        )
        observer.poll()
        XCTAssertTrue(delivered.isEmpty, "changeCount 2 withheld while lazy payload pending")

        // A newer changeCount 3 arrives with a complete payload.
        reader.change = PasteboardChange(
            changeCount: 3,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: ["public.utf8-plain-text": Data("newer".utf8)])]
        )
        observer.poll()
        XCTAssertEqual(delivered.map { $0.changeCount }, [3])

        observer.stop()
    }

    func testObserverDropsSnapshotWhenGenerationChangesDuringMaterialization() {
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
            ])
        )
        let observer = PasteboardObserver(reader: reader, pollInterval: 1)
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }

        reader.change = PasteboardChange(changeCount: 2, items: [
            PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                "public.utf8-plain-text": Data("old-generation".utf8)
            ])
        ])
        // The first currentChangeCount() is the observed generation. The
        // second is sampled after read(); it simulates a write racing the
        // materialization and must invalidate that snapshot.
        reader.forcedChangeCounts = [2, 3]
        observer.poll()
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(reader.readCount, 1)

        observer.stop()
    }

    func testObserverStopClearsCrossPollRetryState() {
        // stop()/restart must not inherit cross-poll retry state from a
        // previous session. Seed a pending entry, stop the observer, then
        // restart and confirm the same changeCount is no longer treated as
        // "still pending" — it must either be delivered fresh (if it differs
        // from lastChangeCount) or ignored (if it matches), but never
        // withheld as a stale retry.
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: ["public.utf8-plain-text": Data("seed".utf8)])
            ])
        )
        let retryState = MacClippyPasteboardReadRetryState(maxAttempts: 4)
        let observer = PasteboardObserver(reader: reader, pollInterval: 1, retryState: retryState)
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }

        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["com.lazy"], representations: [:])]
        )
        observer.poll()
        XCTAssertTrue(retryState.hasPending, "retry state should hold the pending changeCount 2")
        XCTAssertTrue(delivered.isEmpty, "changeCount 2 withheld while lazy payload pending")

        observer.stop()
        XCTAssertFalse(retryState.hasPending, "stop() must clear all cross-poll retry state")

        // Restart: lastChangeCount is re-seeded from the current reader state
        // (changeCount 2), so a new changeCount 3 with a complete payload
        // must deliver immediately. There must be no leftover pending entry
        // that could withhold it.
        observer.start { delivered.append($0) }
        XCTAssertFalse(retryState.hasPending, "restart must not re-seed stale retry state")

        reader.change = PasteboardChange(
            changeCount: 3,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: ["public.utf8-plain-text": Data("after-restart".utf8)])]
        )
        observer.poll()
        XCTAssertEqual(delivered.map { $0.changeCount }, [3], "no stale retry state should withhold the post-restart change")

        observer.stop()
    }

    func testObserverStopResetsWriteSentinelPendingTokens() {
        // stop()/restart must not inherit the write sentinel's pending tokens
        // from a previous session. Register a token, stop the observer, then
        // confirm the sentinel has no pending tokens so a restart cannot
        // suppress a recapture that was actually a stale internal write from
        // the prior session.
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: ["public.utf8-plain-text": Data("seed".utf8)])
            ])
        )
        let sentinel = MacClippyPasteboardWriteSentinel()
        sentinel.beginWrite(expectedChangeCount: 2)
        sentinel.beginWrite(expectedChangeCount: 3)
        XCTAssertEqual(sentinel.pendingCount, 2)

        let observer = PasteboardObserver(reader: reader, writeSentinel: sentinel, pollInterval: 1)
        observer.start { _ in }

        observer.stop()
        XCTAssertEqual(sentinel.pendingCount, 0, "stop() must reset the write sentinel's pending tokens")
        XCTAssertFalse(sentinel.consume(changeCount: 2), "stale token from prior session must not suppress recapture")
        XCTAssertFalse(sentinel.consume(changeCount: 3))
    }

    func testObserverConcurrentStartStopCallsAreSerialized() {
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [])
        )
        let observer = PasteboardObserver(reader: reader, pollInterval: 1)
        let queue = DispatchQueue(label: "MacClippyObserverLifecycleTests", attributes: .concurrent)
        let group = DispatchGroup()

        for index in 0..<32 {
            group.enter()
            queue.async {
                if index.isMultiple(of: 2) {
                    observer.start { _ in }
                } else {
                    observer.stop()
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        observer.stop()
    }

    func testObserverConcurrentConfigurationUpdatesStayOrderedWithPolling() {
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [])
        )
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 1,
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 1)
        )
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }

        let queue = DispatchQueue(label: "MacClippyObserverConfigurationTests", attributes: .concurrent)
        let group = DispatchGroup()
        for index in 0..<64 {
            group.enter()
            queue.async {
                observer.updateExclusionRules(
                    CaptureExclusionRules(
                        excludedAppBundleIDs: index.isMultiple(of: 2) ? ["com.example.blocked"] : []
                    )
                )
                observer.setCapturePaused(index.isMultiple(of: 3))
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        // These final writes are ordered ahead of the synchronous poll on the
        // observer's lifecycle queue. The new generation must therefore be
        // delivered using the final, unpaused configuration rather than a
        // partially applied configuration from the concurrent batch.
        observer.updateExclusionRules(CaptureExclusionRules())
        observer.setCapturePaused(false)
        reader.change = PasteboardChange(
            changeCount: 2,
            items: [
                PasteboardItem(
                    types: ["public.utf8-plain-text"],
                    representations: ["public.utf8-plain-text": Data("ordered".utf8)]
                )
            ]
        )
        observer.poll()

        XCTAssertEqual(delivered.map(\.changeCount), [2])
        observer.stop()
    }

    func testObserverProductionDefaultQueueIsNotMain() {
        // The production default queue must NOT be the main queue so polling
        // and the synchronous retry helper's sleeps never block the UI. We
        // assert this by delivering a change through the real timer fire path
        // and confirming the handler runs on a background queue whose label
        // matches the production poll queue constant. A main-queue default
        // would run the handler on the main thread.
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: ["public.utf8-plain-text": Data("seed".utf8)])
            ])
        )
        // Use the production default queue explicitly (no queue argument) so
        // the test exercises the same default the runtime relies on.
        let observer = PasteboardObserver(reader: reader, pollInterval: 0.01)
        let expectation = XCTestExpectation(description: "handler runs on the production poll queue")

        var handlerQueueLabel: String?
        var handlerIsMainThread: Bool?
        observer.start { _ in
            // __dispatch_queue_get_label(nil) returns the label of the queue
            // that is currently executing this block; DispatchQueue.currentLabel
            // is not available on this toolchain.
            handlerQueueLabel = String(cString: __dispatch_queue_get_label(nil))
            handlerIsMainThread = Thread.isMainThread
            expectation.fulfill()
        }

        // Bump the changeCount so the first timer fire delivers a change.
        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: ["public.utf8-plain-text": Data("delivered".utf8)])]
        )

        wait(for: [expectation], timeout: 5)
        observer.stop()

        XCTAssertEqual(handlerQueueLabel, MacClippyPasteboardObserver.productionPollQueueLabel,
                       "production default queue must be the dedicated poll queue")
        XCTAssertEqual(handlerIsMainThread, false,
                       "production default queue must not be the main queue")
    }

    // A test reader that models a lazy provider: read() returns the current
    // `change`, and reread(...) returns `rereadResult` when set (otherwise it
    // falls back to the default protocol implementation that returns the
    // change unchanged). This lets tests deterministically simulate a payload
    // that is unavailable on the first poll and materialized on a later poll.
    private final class SteppingTestPasteboardReader: PasteboardReading {
        var change: PasteboardChange
        var rereadResult: PasteboardChange?
        var forcedChangeCounts: [Int] = []
        private(set) var readCount = 0; private(set) var rereadCount = 0

        init(initial: PasteboardChange) {
            self.change = initial
        }

        func currentChangeCount() -> Int {
            if !forcedChangeCounts.isEmpty {
                return forcedChangeCounts.removeFirst()
            }
            return change.changeCount
        }

        func read() -> PasteboardChange {
            readCount += 1
            return change
        }

        func reread(change: PasteboardChange, unavailableTypes: [(itemIndex: Int, uti: String)]) -> PasteboardChange {
            rereadCount += 1
            return rereadResult ?? change
        }
    }
}
