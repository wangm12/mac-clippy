import AppKit
import Foundation
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

extension PasteboardObserverLifecycleTests {
    func testObserverRestartConsumesCurrentWriteAndPreservesFutureToken() {
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 2, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
            ])
        )
        let sentinel = MacClippyPasteboardWriteSentinel()
        sentinel.beginWrite(expectedChangeCount: 1)
        sentinel.beginWrite(expectedChangeCount: 2)
        sentinel.beginWrite(expectedChangeCount: 3)
        XCTAssertEqual(sentinel.pendingCount, 3)

        let observer = PasteboardObserver(reader: reader, writeSentinel: sentinel, pollInterval: 1)
        var delivered: [Int] = []
        observer.start { delivered.append($0.changeCount) }
        observer.poll()
        XCTAssertEqual(sentinel.pendingCount, 1, "restart prunes stale token and consumes the current write")
        XCTAssertFalse(sentinel.consume(changeCount: 1), "older token must not survive the restart")
        XCTAssertFalse(sentinel.consume(changeCount: 2), "current token was consumed by restart")

        observer.stop()
        observer.poll()
        XCTAssertEqual(sentinel.pendingCount, 1, "future token remains until restart can compare generations")
        observer.start { delivered.append($0.changeCount) }
        observer.poll()

        reader.change = PasteboardChange(changeCount: 3, items: [])
        observer.poll()
        XCTAssertTrue(delivered.isEmpty, "the retained future internal-write token suppresses exact match")
        XCTAssertEqual(sentinel.pendingCount, 0)

        reader.change = PasteboardChange(changeCount: 4, items: [
            PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                "public.utf8-plain-text": Data("external".utf8)
            ])
        ])
        observer.poll()
        XCTAssertEqual(delivered, [4])
        observer.stop()
    }

    func testObserverProductionDefaultQueueIsNotMain() {
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
            ])
        )
        let observer = PasteboardObserver(reader: reader, pollInterval: 0.01)
        let expectation = XCTestExpectation(description: "handler runs on the production poll queue")
        var handlerQueueLabel: String?
        var handlerIsMainThread: Bool?
        observer.start { _ in
            handlerQueueLabel = String(cString: __dispatch_queue_get_label(nil))
            handlerIsMainThread = Thread.isMainThread
            expectation.fulfill()
        }
        observer.poll()
        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                "public.utf8-plain-text": Data("delivered".utf8)
            ])]
        )

        wait(for: [expectation], timeout: 5)
        observer.stop()

        XCTAssertEqual(handlerQueueLabel, MacClippyPasteboardObserver.productionPollQueueLabel)
        XCTAssertEqual(handlerIsMainThread, false)
    }
}
