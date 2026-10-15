import AppKit
import Foundation
import XCTest

import MacClippyCore
import MacClippyPlatformTestObjCSupport
@_spi(Testing) @testable import MacClippyPlatform

final class MacClippyObserverReadFailureTests: XCTestCase {
    func testNativeReadExceptionLeavesCurrentGenerationPendingUntilControlRecovery() throws {
        let pasteboard = MacClippyMakeMalformedPasteboard(0)
        let coordinator = MacClippyPasteboardAccessCoordinator.shared(for: pasteboard)
        let nativeFailures = LockedArray<MacClippyObjectiveCException>()
        let reader = MacClippySystemPasteboardReader(
            pasteboard: pasteboard,
            sourceAppBundleID: { nil },
            accessCoordinator: coordinator,
            onReadFailure: { nativeFailures.append($0) }
        )
        let observer = MacClippyPasteboardObserver(
            reader: reader,
            pollInterval: 60,
            queue: DispatchQueue(label: "MacClippyReadFailureTests.native"),
            secondsSinceLastUserInput: { 0 }
        )
        observer.disableAutomaticPollingForTesting()
        let deliveries = LockedArray<Int>()
        observer.start { deliveries.append($0.changeCount) }
        observer.poll()
        let seedCount = try MacClippyNativePasteboard.changeCount(of: pasteboard)

        MacClippySetSyntheticPasteboardContents(pasteboard, 20, "recovered")
        let failedGeneration = try MacClippyNativePasteboard.changeCount(of: pasteboard)
        MacClippyNativePasteboard.injectExceptionForTesting(after: "pasteboard.item-data")
        observer.poll()

        XCTAssertEqual(
            observer.lastChangeCount,
            seedCount,
            "a failed native materialization cannot consume the generation"
        )
        XCTAssertTrue(
            deliveries.values.isEmpty,
            "a failed read must not dispatch a partial or synthetic-empty pasteboard event"
        )
        XCTAssertEqual(nativeFailures.values.map(\.operation), ["pasteboard.item-data"])
        assertCoordinatorCanBeAcquiredFromAnotherQueue(coordinator)

        let completionCounts = requestCurrentGenerationRead(observer)

        guard case let .success(change) = reader.readOutcome(shouldContinue: { true }) else {
            observer.stop()
            return XCTFail("production reader should succeed after the one-shot native fault")
        }
        observer.stop()

        XCTAssertEqual(change.changeCount, failedGeneration)
        XCTAssertEqual(change.items.first?.string(forType: NSPasteboard.PasteboardType.string.rawValue), "recovered")
        XCTAssertEqual(completionCounts.count, 1)
        XCTAssertEqual(completionCounts.first!, failedGeneration)
        XCTAssertEqual(
            deliveries.values,
            [failedGeneration],
            "the recovered external generation is delivered exactly once"
        )
    }

    private func requestCurrentGenerationRead(
        _ observer: MacClippyPasteboardObserver
    ) -> [Int?] {
        let completed = expectation(description: "recovery control completes once")
        let changeCounts = LockedArray<Int?>()
        observer.requestCurrentGenerationRead { changeCount in
            changeCounts.append(changeCount)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 3)
        return changeCounts.values
    }

    func testOutcomeFailureRetriesWithoutConsumingAndTerminalFailureIsDiagnosedOnce() {
        let change = textChange(2, "current")
        let reader = ScriptedOutcomeReader(initial: textChange(1, "seed"), outcomes: [
            .failed(MacClippyPasteboardReadFailure(operation: "synthetic.read", message: "injected")),
            .success(change)
        ])
        let observer = makeObserver(reader)
        var deliveries: [Int] = []
        observer.start { deliveries.append($0.changeCount) }
        observer.poll()
        reader.change = change

        observer.poll()
        XCTAssertEqual(observer.lastChangeCount, 1)
        XCTAssertTrue(deliveries.isEmpty)
        observer.poll()

        XCTAssertEqual(deliveries, [2])
        XCTAssertEqual(observer.lastChangeCount, 2)
        observer.stop()

        let failingReader = ScriptedOutcomeReader(initial: textChange(1, "seed"), alwaysFailing: true)
        let recorder = MacClippyDiagnosticsRecorder(capacity: 8)
        let failingObserver = makeObserver(failingReader, recorder: recorder)
        var failedDeliveries: [Int] = []
        failingObserver.start { failedDeliveries.append($0.changeCount) }
        failingObserver.poll()
        failingReader.change = change

        for _ in 0..<MacClippyPasteboardObserver.maximumReadFailureAttempts {
            failingObserver.poll()
        }
        failingObserver.poll()

        let events = recorder.recentEvents().filter { $0.code == .pasteboardReadFailed }
        XCTAssertEqual(failingReader.readCount, MacClippyPasteboardObserver.maximumReadFailureAttempts)
        XCTAssertEqual(failedDeliveries, [])
        XCTAssertEqual(failingObserver.lastChangeCount, 2)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.retryCount, MacClippyPasteboardObserver.maximumReadFailureAttempts)
        failingObserver.stop()
    }

    private func makeObserver(
        _ reader: ScriptedOutcomeReader,
        recorder: MacClippyDiagnosticsRecorder = MacClippyDiagnosticsRecorder(capacity: 8)
    ) -> MacClippyPasteboardObserver {
        let observer = MacClippyPasteboardObserver(
            reader: reader,
            pollInterval: 60,
            queue: DispatchQueue(label: "MacClippyReadFailureTests.scripted.\(UUID().uuidString)"),
            diagnosticsRecorder: recorder,
            secondsSinceLastUserInput: { 0 }
        )
        observer.disableAutomaticPollingForTesting()
        return observer
    }

    private func assertCoordinatorCanBeAcquiredFromAnotherQueue(
        _ coordinator: MacClippyPasteboardAccessCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let acquired = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            coordinator.withAccess {
                acquired.signal()
                return ()
            }
        }
        XCTAssertEqual(acquired.wait(timeout: .now() + 2), .success, file: file, line: line)
    }

    private func textChange(_ count: Int, _ text: String) -> PasteboardChange {
        PasteboardChange(
            changeCount: count,
            items: [PasteboardItem(
                types: [NSPasteboard.PasteboardType.string.rawValue],
                representations: [NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]
            )]
        )
    }
}

private final class ScriptedOutcomeReader: PasteboardReading {
    var change: PasteboardChange
    private var outcomes: [MacClippyPasteboardReadOutcome]
    private let alwaysFailing: Bool
    private(set) var readCount = 0

    init(
        initial: PasteboardChange,
        outcomes: [MacClippyPasteboardReadOutcome] = [],
        alwaysFailing: Bool = false
    ) {
        change = initial
        self.outcomes = outcomes
        self.alwaysFailing = alwaysFailing
    }

    func currentChangeCount() -> Int { change.changeCount }
    func read() -> PasteboardChange { change }

    func readOutcome(shouldContinue: () -> Bool) -> MacClippyPasteboardReadOutcome {
        readCount += 1
        guard shouldContinue() else { return .cancelled }
        if alwaysFailing {
            return .failed(MacClippyPasteboardReadFailure(operation: "synthetic.read", message: "persistent"))
        }
        guard outcomes.isEmpty else { return outcomes.removeFirst() }
        return .success(change)
    }
}

private final class LockedArray<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
