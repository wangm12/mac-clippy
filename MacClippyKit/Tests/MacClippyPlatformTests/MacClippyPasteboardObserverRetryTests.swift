import AppKit
import Foundation
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class MacClippyPasteboardObserverRetryTests: XCTestCase {
    func testObserverDefaultPollIntervalIsFiftyMilliseconds() {
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [])
        )
        let observer = PasteboardObserver(reader: reader)

        XCTAssertEqual(observer.pollInterval, 0.05, accuracy: 0.000_001)
    }

    func testObserverWithholdsDeliveryUntilLazyPayloadArrivesAcrossPolls() {
        // A lazy provider advertises a UTI whose payload is unavailable on the
        // first poll for changeCount 2, then materializes it on a later poll.
        // The observer must withhold lastChangeCount advancement and delivery
        // until the payload arrives, then deliver the complete change.
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
            ])
        )
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 1,
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 4)
        )
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }
        observer.poll()

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
        XCTAssertEqual(
            reader.readCount,
            1,
            "the initial generation change should be the only full read before retry"
        )

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
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
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
        observer.poll()

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
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
            ])
        )
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 1,
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 4)
        )
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }
        observer.poll()

        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                "public.utf8-plain-text": Data("ready".utf8)
            ])]
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
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
            ])
        )
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 1,
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 4)
        )
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }
        observer.poll()

        reader.change = PasteboardChange(
            changeCount: 2,
            items: [PasteboardItem(types: ["com.lazy"], representations: [:])]
        )
        observer.poll()
        XCTAssertTrue(delivered.isEmpty, "changeCount 2 withheld while lazy payload pending")

        // A newer changeCount 3 arrives with a complete payload.
        reader.change = PasteboardChange(
            changeCount: 3,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                "public.utf8-plain-text": Data("newer".utf8)
            ])]
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
        observer.poll()

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
}
