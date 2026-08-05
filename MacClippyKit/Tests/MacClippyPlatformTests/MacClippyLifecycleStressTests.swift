import Foundation
import XCTest

import MacClippyPlatform

/// Opt-in lifecycle pressure checks. The normal suite already covers the
/// state machine; this fixture repeatedly creates/cancels the timer and
/// exercises the same serial lifecycle queue used by production.
final class MacClippyLifecycleStressTests: XCTestCase {
    func testObserverStartPollStopRemainsIdempotentAcrossTenThousandCycles() {
        guard ProcessInfo.processInfo.environment["MACCLIPPY_RUN_STRESS_TESTS"] == "1" else { return }

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
            reader.advance(to: cycle)
            observer.poll()
            observer.stop()
        }

        XCTAssertEqual(delivered, cycleCount)
        let duration = Date().timeIntervalSince(start)
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
