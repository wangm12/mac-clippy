import Foundation
import XCTest

import MacClippyPlatform

/// Opt-in lifecycle pressure checks. The normal suite already covers the
/// state machine; this fixture repeatedly creates/cancels the timer and
/// exercises the same serial lifecycle queue used by production.
@MainActor
final class MacClippyLifecycleStressTests: XCTestCase {
    func testObserverStartPollStopRemainsIdempotentAcrossTenThousandCycles() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACCLIPPY_RUN_STRESS_TESTS"] == "1",
            "Set MACCLIPPY_RUN_STRESS_TESTS=1 to run the 10,000-cycle fixture."
        )

        let reader = SteppingReader()
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 60,
            queue: DispatchQueue(label: "MacClippyLifecycleStressTests")
        )
        var delivered = 0
        let cycleCount = 10_000
        let start = Date()

        for cycle in 1...cycleCount {
            observer.start { _ in delivered += 1 }
            // start() is intentionally non-blocking in production. Establish
            // the start barrier before changing the reader; otherwise the
            // queued start may snapshot this cycle's changeCount as its
            // initial baseline and there would be nothing new to deliver.
            observer.poll()
            reader.advance(to: cycle)
            observer.poll()
            observer.stop()
        }

        XCTAssertEqual(delivered, cycleCount)
        let duration = Date().timeIntervalSince(start)
        XCTAssertLessThan(duration, 30, "observer lifecycle stress exceeded the time budget")
        XCTContext.runActivity(named: "MacClippy observer lifecycle stress") { activity in
            activity.add(XCTAttachment(string: "cycles=\(cycleCount)"))
            activity.add(XCTAttachment(string: "seconds=\(duration)"))
        }
    }

    private final class SteppingReader: PasteboardReading {
        private var change = PasteboardChange(changeCount: 0, items: [])

        func advance(to changeCount: Int) {
            change = PasteboardChange(
                changeCount: changeCount,
                items: [
                    PasteboardItem(
                        types: ["public.utf8-plain-text"],
                        representations: [
                            "public.utf8-plain-text": Data([UInt8(1)])
                        ]
                    )
                ]
            )
        }

        func currentChangeCount() -> Int { change.changeCount }

        func read() -> PasteboardChange { change }
    }
}
