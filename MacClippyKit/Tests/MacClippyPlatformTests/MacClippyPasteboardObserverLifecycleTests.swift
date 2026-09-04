import AppKit
import Foundation
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class PasteboardObserverLifecycleTests: XCTestCase {
    func testObserverStopClearsCrossPollRetryState() {
        // stop()/restart must not inherit cross-poll retry state from a
        // previous session. Seed a pending entry, stop the observer, then
        // restart and confirm the same changeCount is no longer treated as
        // "still pending" — it must either be delivered fresh (if it differs
        // from lastChangeCount) or ignored (if it matches), but never
        // withheld as a stale retry.
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
            ])
        )
        let retryState = MacClippyPasteboardReadRetryState(maxAttempts: 4)
        let observer = PasteboardObserver(reader: reader, pollInterval: 1, retryState: retryState)
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }
        observer.poll()

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
        observer.poll()
        XCTAssertFalse(retryState.hasPending, "restart must not re-seed stale retry state")

        reader.change = PasteboardChange(
            changeCount: 3,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                "public.utf8-plain-text": Data("after-restart".utf8)
            ])]
        )
        observer.poll()
        XCTAssertEqual(
            delivered.map { $0.changeCount },
            [3],
            "no stale retry state should withhold the post-restart change"
        )

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
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
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
        observer.poll()

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
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
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
        observer.poll()

        // Bump the changeCount so the first timer fire delivers a change.
        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                "public.utf8-plain-text": Data("delivered".utf8)
            ])]
        )

        wait(for: [expectation], timeout: 5)
        observer.stop()

        XCTAssertEqual(
            handlerQueueLabel,
            MacClippyPasteboardObserver.productionPollQueueLabel,
            "production default queue must be the dedicated poll queue"
        )
        XCTAssertEqual(
            handlerIsMainThread,
            false,
            "production default queue must not be the main queue"
        )
    }

    func testSleepSuspendsThePollingTimerWithoutAdvancingLastChangeCount() {
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
            ])
        )
        let observer = PasteboardObserver(reader: reader, pollInterval: 1)
        var delivered: [Int] = []
        observer.start { delivered.append($0.changeCount) }
        observer.poll()
        XCTAssertTrue(observer.hasPollingTimerForTesting())
        XCTAssertFalse(observer.isPollingSuspendedForTesting())

        observer.setPollingSuspended(true)
        XCTAssertTrue(observer.isPollingSuspendedForTesting())
        XCTAssertFalse(
            observer.hasPollingTimerForTesting(),
            "sleep must cancel the 50ms timer instead of leaving it to spin"
        )

        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                "public.utf8-plain-text": Data("during-sleep".utf8)
            ])]
        )
        observer.poll()
        XCTAssertTrue(
            delivered.isEmpty,
            "a manual poll during sleep must not deliver or eat the generation"
        )

        observer.setPollingSuspended(false)
        XCTAssertFalse(observer.isPollingSuspendedForTesting())
        XCTAssertTrue(observer.hasPollingTimerForTesting())
        observer.poll()
        XCTAssertEqual(delivered, [2], "wake must resume polling and see the slept-through change")

        observer.stop()
    }

    func testBackgroundActivitySlowsThePollingIntervalWithoutAdvancingLastChangeCount() {
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
            ])
        )
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 0.05,
            secondsSinceLastUserInput: { 1 }
        )
        var delivered: [Int] = []
        observer.start { delivered.append($0.changeCount) }
        observer.poll()
        XCTAssertEqual(
            observer.pollIntervalForTesting(),
            MacClippyPasteboardPollPolicy.pollInterval(for: .foreground),
            accuracy: 0.000_001
        )

        observer.setPollActivity(.background)
        XCTAssertEqual(
            observer.pollIntervalForTesting(),
            MacClippyPasteboardPollPolicy.pollInterval(for: .background),
            accuracy: 0.000_001
        )
        XCTAssertTrue(observer.hasPollingTimerForTesting())

        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                "public.utf8-plain-text": Data("after-background".utf8)
            ])]
        )
        observer.poll()
        XCTAssertEqual(delivered, [2], "changing the awake poll interval must not swallow a generation")
        observer.stop()
    }

    func testSleepKeepsTheTimerCancelledWhenPollActivityChanges() {
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
            ])
        )
        let observer = PasteboardObserver(reader: reader, pollInterval: 0.05)
        observer.start { _ in }
        observer.poll()
        observer.setPollingSuspended(true)
        observer.setPollActivity(.background)

        XCTAssertTrue(observer.isPollingSuspendedForTesting())
        XCTAssertFalse(
            observer.hasPollingTimerForTesting(),
            "sleep must keep the timer cancelled even if app activity changes"
        )
        XCTAssertEqual(
            observer.pollIntervalForTesting(),
            MacClippyPasteboardPollPolicy.pollInterval(for: .background),
            accuracy: 0.000_001
        )
        observer.stop()
    }

    func testIdleSessionUsesSlowPollUntilACopyStartsABurst() {
        let secondsSinceLastUserInput: TimeInterval = 120
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
            ])
        )
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 0.05,
            secondsSinceLastUserInput: { secondsSinceLastUserInput }
        )
        observer.start { _ in }
        observer.poll()
        XCTAssertEqual(
            observer.pollIntervalForTesting(),
            MacClippyPasteboardPollPolicy.pollInterval(for: .background),
            accuracy: 0.000_001
        )

        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                "public.utf8-plain-text": Data("burst".utf8)
            ])]
        )
        observer.poll()
        XCTAssertEqual(
            observer.pollIntervalForTesting(),
            MacClippyPasteboardPollPolicy.pollInterval(for: .foreground),
            accuracy: 0.000_001,
            "a just-seen copy must keep the fast poll even while the user looks idle"
        )
        observer.stop()
    }
}
