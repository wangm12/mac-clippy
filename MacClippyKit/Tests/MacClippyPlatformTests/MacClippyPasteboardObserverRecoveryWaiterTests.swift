import Foundation
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class MacClippyRecoveryWaiterTests: XCTestCase {
    func testSuspendedRecoveryWaitersAreBoundedAndCompleteAfterResume() {
        let observer = makeObserver()
        observer.start { _ in }
        observer.poll()
        observer.setPollingSuspended(true)
        observer.poll()

        let completed = expectation(description: "all bounded recovery requests complete exactly once")
        completed.expectedFulfillmentCount = 35
        let results = WaiterResults()
        for _ in 0..<35 {
            observer.requestCurrentGenerationRead { result in
                results.append(result)
                completed.fulfill()
            }
        }
        observer.poll()
        XCTAssertEqual(results.values.count, 3, "three over-capacity requests fail promptly with nil")
        XCTAssertTrue(results.values.allSatisfy { $0 == nil })

        observer.setPollingSuspended(false)
        observer.poll()
        wait(for: [completed], timeout: 3)
        observer.stop()

        XCTAssertEqual(results.values.count, 35)
        XCTAssertEqual(results.values.filter { $0 == nil }.count, 3)
        XCTAssertEqual(results.values.compactMap { $0 }.count, 32)
        XCTAssertEqual(Set(results.values.compactMap { $0 }), Set([1]))
    }

    func testStopRestartAndDeinitResolvePendingWaitersOnce() {
        let observer = makeObserver()
        observer.start { _ in }
        observer.poll()
        observer.setPollingSuspended(true)
        observer.poll()

        let stopped = expectation(description: "stop resolves pending recovery read")
        let stopResults = WaiterResults()
        observer.requestCurrentGenerationRead { result in
            stopResults.append(result)
            stopped.fulfill()
        }
        observer.poll()
        observer.stop()
        observer.poll()
        wait(for: [stopped], timeout: 2)

        observer.start { _ in }
        observer.poll()
        XCTAssertEqual(stopResults.values.count, 1)
        XCTAssertEqual(stopResults.values.first!, nil)
        observer.stop()
        observer.poll()

        let deinitialized = expectation(description: "deinit resolves pending recovery read")
        let deinitResults = WaiterResults()
        var pendingObserver: MacClippyPasteboardObserver? = makeObserver()
        pendingObserver?.start { _ in }
        pendingObserver?.poll()
        pendingObserver?.setPollingSuspended(true)
        pendingObserver?.poll()
        pendingObserver?.requestCurrentGenerationRead { result in
            deinitResults.append(result)
            deinitialized.fulfill()
        }
        pendingObserver?.poll()
        pendingObserver = nil

        wait(for: [deinitialized], timeout: 2)
        XCTAssertEqual(deinitResults.values.count, 1)
        XCTAssertEqual(deinitResults.values.first!, nil)
    }

    private func makeObserver() -> MacClippyPasteboardObserver {
        let observer = MacClippyPasteboardObserver(
            reader: SteppingTestPasteboardReader(initial: PasteboardChange(
                changeCount: 1,
                items: [PasteboardItem(
                    types: ["public.utf8-plain-text"],
                    representations: ["public.utf8-plain-text": Data("seed".utf8)]
                )]
            )),
            pollInterval: 60,
            queue: DispatchQueue(label: "MacClippyRecoveryWaiterTests.\(UUID().uuidString)"),
            secondsSinceLastUserInput: { 0 }
        )
        observer.disableAutomaticPollingForTesting()
        return observer
    }
}

private final class WaiterResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int?] = []

    func append(_ value: Int?) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
