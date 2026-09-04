import AppKit
import Foundation
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class PasteboardObserverDiagnosticTests: XCTestCase {
    func testObserverRecordsMissedChangeCountDiagnosticAndDeliversLatestChange() {
        let diagnosticsRecorder = MacClippyDiagnosticsRecorder(capacity: 4)
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
            diagnosticsRecorder: diagnosticsRecorder
        )
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }
        observer.poll()

        reader.change = PasteboardChange(changeCount: 3, items: [
            PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                "public.utf8-plain-text": Data("latest".utf8)
            ])
        ])
        observer.poll()

        XCTAssertEqual(delivered.map(\.changeCount), [3])
        XCTAssertEqual(
            diagnosticsRecorder.recentEvents().filter { $0.code == .missedChangeCounts }.count,
            1
        )
        XCTAssertEqual(diagnosticsRecorder.recentEvents().last?.category, .capture)
        observer.stop()
    }

    func testObserverRecordsMissedChangeCountDiagnosticBeforeSuppressingInternalWrite() {
        let diagnosticsRecorder = MacClippyDiagnosticsRecorder(capacity: 4)
        let sentinel = MacClippyPasteboardWriteSentinel()
        let reader = SteppingTestPasteboardReader(
            initial: PasteboardChange(changeCount: 1, items: [
                PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                    "public.utf8-plain-text": Data("seed".utf8)
                ])
            ])
        )
        let observer = PasteboardObserver(
            reader: reader,
            writeSentinel: sentinel,
            pollInterval: 1,
            diagnosticsRecorder: diagnosticsRecorder
        )
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }
        observer.poll()

        sentinel.beginWrite(expectedChangeCount: 3)
        reader.change = PasteboardChange(changeCount: 3, items: [
            PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                "public.utf8-plain-text": Data("internal".utf8)
            ])
        ])
        observer.poll()

        XCTAssertTrue(delivered.isEmpty, "internal writes must still be suppressed")
        XCTAssertEqual(sentinel.pendingCount, 0, "the sentinel token should be consumed")
        XCTAssertEqual(
            diagnosticsRecorder.recentEvents().filter { $0.code == .missedChangeCounts }.count,
            1
        )
        observer.stop()
    }

    func testObserverRecordsMissedChangeCountDiagnosticOnlyOnceDuringRetryPolls() {
        let diagnosticsRecorder = MacClippyDiagnosticsRecorder(capacity: 4)
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
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 4),
            diagnosticsRecorder: diagnosticsRecorder
        )
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }
        observer.poll()

        reader.change = PasteboardChange(
            changeCount: 3,
            items: [PasteboardItem(types: ["public.utf8-plain-text", "com.lazy"], representations: [
                "public.utf8-plain-text": Data("hi".utf8)
            ])]
        )
        observer.poll()
        observer.poll()

        XCTAssertTrue(delivered.isEmpty, "delivery should remain withheld while lazy payload is pending")
        XCTAssertEqual(
            diagnosticsRecorder.recentEvents().filter { $0.code == .missedChangeCounts }.count,
            1
        )
        observer.stop()
    }

    func testObserverRecoversIntermediateGenerationsWhenChangeCountJumps() {
        let diagnosticsRecorder = MacClippyDiagnosticsRecorder(capacity: 4)
        let reader = HistoryTestPasteboardReader(generations: [
            1: Self.textChange(changeCount: 1, text: "seed"),
            2: Self.textChange(changeCount: 2, text: "first"),
            3: Self.textChange(changeCount: 3, text: "second"),
        ])
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 1,
            diagnosticsRecorder: diagnosticsRecorder
        )
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }
        observer.poll()

        reader.currentChangeCountValue = 3
        observer.poll()

        XCTAssertEqual(delivered.map(\.changeCount), [2, 3])
        XCTAssertEqual(
            delivered.map { $0.items[0].string(forType: "public.utf8-plain-text") },
            ["first", "second"]
        )
        let missed = diagnosticsRecorder.recentEvents().filter { $0.code == .missedChangeCounts }
        XCTAssertEqual(missed.count, 1)
        XCTAssertEqual(missed.last?.recoveryAction, "recover_intermediate_generations")
        observer.stop()
    }

    func testObserverCatchUpSkipsInternalWritesAndDeliversTheRest() {
        let diagnosticsRecorder = MacClippyDiagnosticsRecorder(capacity: 4)
        let sentinel = MacClippyPasteboardWriteSentinel()
        let reader = HistoryTestPasteboardReader(generations: [
            1: Self.textChange(changeCount: 1, text: "seed"),
            2: Self.textChange(changeCount: 2, text: "kept-a"),
            3: Self.textChange(changeCount: 3, text: "internal"),
            4: Self.textChange(changeCount: 4, text: "kept-b"),
        ])
        let observer = PasteboardObserver(
            reader: reader,
            writeSentinel: sentinel,
            pollInterval: 1,
            diagnosticsRecorder: diagnosticsRecorder
        )
        var delivered: [PasteboardChange] = []
        observer.start { delivered.append($0) }
        observer.poll()

        sentinel.beginWrite(expectedChangeCount: 3)
        reader.currentChangeCountValue = 4
        observer.poll()

        XCTAssertEqual(delivered.map(\.changeCount), [2, 4])
        XCTAssertEqual(
            delivered.map { $0.items[0].string(forType: "public.utf8-plain-text") },
            ["kept-a", "kept-b"]
        )
        XCTAssertEqual(sentinel.pendingCount, 0)
        XCTAssertEqual(
            diagnosticsRecorder.recentEvents().filter { $0.code == .missedChangeCounts }.count,
            1
        )
        observer.stop()
    }

    private static func textChange(changeCount: Int, text: String) -> PasteboardChange {
        PasteboardChange(
            changeCount: changeCount,
            items: [PasteboardItem(types: ["public.utf8-plain-text"], representations: [
                "public.utf8-plain-text": Data(text.utf8)
            ])]
        )
    }
}

final class HistoryTestPasteboardReader: PasteboardReading {
    var generations: [Int: PasteboardChange]
    var currentChangeCountValue: Int

    init(generations: [Int: PasteboardChange]) {
        self.generations = generations
        self.currentChangeCountValue = generations.keys.min() ?? 0
    }

    func currentChangeCount() -> Int {
        currentChangeCountValue
    }

    func read() -> PasteboardChange {
        generations[currentChangeCountValue] ?? PasteboardChange(changeCount: currentChangeCountValue, items: [])
    }

    func read(changeCount: Int, shouldContinue: () -> Bool) -> PasteboardChange? {
        guard shouldContinue() else { return nil }
        return generations[changeCount]
    }
}
