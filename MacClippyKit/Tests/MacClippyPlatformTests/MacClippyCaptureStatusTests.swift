import XCTest
import MacClippyCore
@testable import MacClippyPlatform

final class MacClippyCaptureStatusTests: XCTestCase {
    func testStatusTracksPauseAndCancelPendingIgnoresOnObserverQueue() {
        let reader = SteppingTestPasteboardReader(initial: PasteboardChange(changeCount: 1, items: []))
        let observer = PasteboardObserver(reader: reader, pollInterval: 1)
        defer { observer.stop() }
        observer.setCapturePaused(true)
        observer.ignoreNextCopy()
        observer.ignoreNextCopy()
        assertStatus(observer, expected: .init(isPaused: true, remainingIgnoredCopies: 2))
        observer.cancelIgnoredCopies()
        assertStatus(observer, expected: .init(isPaused: true, remainingIgnoredCopies: 0))
        observer.setCapturePaused(false)
        assertStatus(observer, expected: .init())
    }

    private func assertStatus(_ observer: PasteboardObserver, expected: MacClippyCaptureStatus) {
        let finished = expectation(description: "Read observer-owned status")
        observer.readCaptureStatus { status in
            XCTAssertEqual(status, expected)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }
}
