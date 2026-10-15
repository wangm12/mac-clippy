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
