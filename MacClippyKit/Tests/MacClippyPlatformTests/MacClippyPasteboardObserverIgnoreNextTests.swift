import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class MacClippyPasteboardObserverIgnoreNextTests: XCTestCase {
    func testIgnoreNextCopySkipsOneChangeThenResumes() {
        let reader = Reader(change: change(count: 1, text: "seed"))
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 1,
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 1)
        )
        var delivered: [Int] = []
        observer.start { delivered.append($0.changeCount) }
        observer.poll()
        XCTAssertTrue(delivered.isEmpty)

        observer.ignoreNextCopy()
        reader.change = change(count: 2, text: "secret")
        observer.poll()
        XCTAssertTrue(delivered.isEmpty)

        reader.change = change(count: 3, text: "kept")
        observer.poll()
        XCTAssertEqual(delivered, [3])
        observer.stop()
    }

    func testIgnoreNextTokenDoesNotSurviveStopAndStart() {
        let reader = Reader(change: change(count: 1, text: "seed"))
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 1,
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 1)
        )
        var delivered: [Int] = []
        observer.start { delivered.append($0.changeCount) }
        observer.poll()
        observer.ignoreNextCopy()
        observer.stop()

        observer.start { delivered.append($0.changeCount) }
        observer.poll()
        reader.change = change(count: 2, text: "kept")
        observer.poll()
        XCTAssertEqual(delivered, [2])
        observer.stop()
    }

    private func change(count: Int, text: String) -> PasteboardChange {
        PasteboardChange(
            changeCount: count,
            items: [PasteboardItem(
                types: ["public.utf8-plain-text"],
                representations: ["public.utf8-plain-text": Data(text.utf8)]
            )]
        )
    }

    private final class Reader: PasteboardReading {
        var change: PasteboardChange

        init(change: PasteboardChange) {
            self.change = change
        }

        func currentChangeCount() -> Int { change.changeCount }
        func read() -> PasteboardChange { change }
    }
}
