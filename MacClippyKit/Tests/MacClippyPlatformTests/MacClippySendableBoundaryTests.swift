import Foundation
import XCTest

import MacClippyCore
import MacClippyPlatform

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class MacClippySendableBoundaryTests: XCTestCase {
    func testSnippetLookupSnapshotSupportsConcurrentReplaceAndLookup() {
        let snapshot = MacClippySnippetLookupSnapshot()
        let initial = Snippet(name: "Initial", body: "initial", trigger: ";initial")
        snapshot.replace(with: [initial])

        let queue = DispatchQueue(label: "MacClippySnippetSnapshotTests", attributes: .concurrent)
        let group = DispatchGroup()

        for index in 0..<128 {
            group.enter()
            queue.async {
                if index.isMultiple(of: 2) {
                    let snippet = Snippet(
                        name: "Snippet \(index)",
                        body: "body \(index)",
                        trigger: ";trigger\(index)"
                    )
                    snapshot.replace(with: [snippet])
                } else {
                    _ = snapshot.body(for: ";initial")
                    _ = snapshot.body(for: ";trigger\(index - 1)")
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let final = Snippet(name: "Final", body: "final", trigger: ";final")
        snapshot.replace(with: [final])
        XCTAssertEqual(snapshot.body(for: ";final"), "final")
        XCTAssertNil(snapshot.body(for: ";initial"))
    }

    func testPasteboardSentinelConcurrentlyRegistersAndConsumesEveryToken() {
        let sentinel = MacClippyPasteboardWriteSentinel()
        let base = 10_000

        DispatchQueue.concurrentPerform(iterations: 128) { index in
            sentinel.beginWrite(expectedChangeCount: base + index)
        }
        XCTAssertEqual(sentinel.pendingCount, 128)

        let matchedCount = LockedCounter()
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            if sentinel.consume(changeCount: base + index) {
                matchedCount.increment()
            }
        }

        XCTAssertEqual(matchedCount.value, 128)
        XCTAssertEqual(sentinel.pendingCount, 0)
    }

    func testDiagnosticsRecorderKeepsBoundedConsistentSnapshotConcurrently() {
        let recorder = MacClippyDiagnosticsRecorder(capacity: 32)

        DispatchQueue.concurrentPerform(iterations: 256) { index in
            recorder.record(
                MacClippyDiagnosticsEvent(
                    category: .storage,
                    code: .databaseHealthFailed,
                    operation: "concurrency_\(index)"
                )
            )
            recorder.recordMetric(operation: "concurrent_latency", durationMilliseconds: index)
            _ = recorder.recentEvents()
        }

        let events = recorder.recentEvents()
        XCTAssertEqual(events.count, 32)
        XCTAssertTrue(events.allSatisfy { $0.category == .storage })
        XCTAssertTrue(events.allSatisfy { $0.code == .databaseHealthFailed })
        XCTAssertEqual(recorder.metricSnapshot()["concurrent_latency"]?.count, 256)
    }
}
