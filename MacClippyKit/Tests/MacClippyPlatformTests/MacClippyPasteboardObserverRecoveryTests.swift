import Foundation
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

private final class ObserverRecoveryCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func append(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class PasteboardObserverRecoveryTests: XCTestCase {
    func testRestartDoesNotRecoverPrivacyPausedGenerationChangedWhileStopped() {
        assertRestartDoesNotCaptureCurrentGeneration(disposition: .privacyPaused)
    }

    func testRestartDoesNotRecoverIgnoredGenerationChangedWhileStopped() {
        assertRestartDoesNotCaptureCurrentGeneration(disposition: .ignored)
    }

    func testRestartPreservesOwnWriteGenerationBeforeStop() {
        assertRestartDoesNotCaptureCurrentGeneration(disposition: .internalWrite)
    }

    func testRestartedOwnWriteAndPendingIgnoreDoNotSuppressNextCopy() {
        assertRestartDoesNotCaptureCurrentGeneration(disposition: .internalWriteWithPendingIgnore)
    }

    func testCurrentGenerationRecoveryDoesNotRepeatIgnoredOrInternalWrites() {
        verifyIgnoredGenerationStaysConsumed()
        verifyInternalGenerationStaysConsumed()
    }

    func testCurrentGenerationRecoveryDoesNotCapturePrivacyPausedGeneration() {
        let reader = makeReader()
        let observer = PasteboardObserver(reader: reader, pollInterval: 60)
        var deliveredCounts: [Int] = []
        observer.start { deliveredCounts.append($0.changeCount) }
        observer.poll()
        observer.setCapturePaused(true)
        reader.change = textChange(2, "private")
        observer.poll()

        let acknowledged = expectation(description: "paused generation acknowledged after unpause")
        observer.requestCurrentGenerationRead { observedCount in
            XCTAssertEqual(observedCount, 2)
            acknowledged.fulfill()
        }
        observer.setCapturePaused(false)
        observer.poll()
        wait(for: [acknowledged], timeout: 2)
        XCTAssertTrue(deliveredCounts.isEmpty)
        observer.stop()
    }

    func testCurrentGenerationRecoveryCanRetryCapacityRejectedGeneration() {
        let reader = makeReader()
        let observer = PasteboardObserver(reader: reader, pollInterval: 60)
        var shouldAdmit = false
        var attempts: [Int] = []
        let delivered = ObserverRecoveryCounts()
        observer.start(
            admissionHandler: { change in
                attempts.append(change.changeCount)
                guard shouldAdmit else { return nil }
                return MacClippyPasteboardCaptureAdmission { wasPersisted in
                    if wasPersisted { delivered.append(change.changeCount) }
                }
            },
            admittedProjectionHandler: { _, _, admission in
                admission.finish(wasPersisted: true)
            }
        )
        observer.poll()
        reader.change = textChange(2, "capacity-rejected")
        observer.poll()
        XCTAssertEqual(attempts, [2])

        shouldAdmit = true
        assertRecoveryAcknowledges(observer, count: 2)
        XCTAssertEqual(attempts, [2, 2])
        XCTAssertEqual(delivered.snapshot, [2])
        observer.stop()
    }

    private func verifyIgnoredGenerationStaysConsumed() {
        let reader = makeReader()
        let observer = PasteboardObserver(reader: reader, pollInterval: 60)
        var rejectedCounts: [Int] = []
        var deliveredCounts: [Int] = []
        observer.start(
            admissionHandler: { change in
                rejectedCounts.append(change.changeCount)
                return nil
            },
            admittedProjectionHandler: { change, _, admission in
                deliveredCounts.append(change.changeCount)
                admission.finish(wasPersisted: true)
            }
        )
        observer.poll()
        reader.change = textChange(2, "overloaded")
        observer.poll()
        XCTAssertEqual(rejectedCounts, [2])

        observer.ignoreNextCopy()
        reader.change = textChange(3, "ignored")
        observer.poll()
        assertRecoveryAcknowledges(observer, count: 3)
        XCTAssertEqual(rejectedCounts, [2])
        XCTAssertTrue(deliveredCounts.isEmpty)
        observer.stop()
    }

    private func verifyInternalGenerationStaysConsumed() {
        let reader = makeReader()
        let sentinel = MacClippyPasteboardWriteSentinel()
        let observer = PasteboardObserver(
            reader: reader,
            writeSentinel: sentinel,
            pollInterval: 60
        )
        var deliveredCounts: [Int] = []
        observer.start { deliveredCounts.append($0.changeCount) }
        observer.poll()
        sentinel.beginWrite(expectedChangeCount: 2)
        reader.change = textChange(2, "internal")
        observer.poll()
        assertRecoveryAcknowledges(observer, count: 2)
        XCTAssertTrue(deliveredCounts.isEmpty)
        observer.stop()
    }

    private func assertRecoveryAcknowledges(
        _ observer: PasteboardObserver,
        count: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let acknowledged = expectation(description: "generation \(count) acknowledged")
        observer.requestCurrentGenerationRead { observedCount in
            XCTAssertEqual(observedCount, count, file: file, line: line)
            acknowledged.fulfill()
        }
        wait(for: [acknowledged], timeout: 2)
    }

    private enum RestartDisposition: Equatable {
        case privacyPaused
        case ignored
        case internalWrite
        case internalWriteWithPendingIgnore
    }

    private func assertRestartDoesNotCaptureCurrentGeneration(disposition: RestartDisposition) {
        let reader = makeReader()
        let sentinel = disposition == .internalWrite || disposition == .internalWriteWithPendingIgnore
            ? MacClippyPasteboardWriteSentinel()
            : nil
        let observer = PasteboardObserver(reader: reader, writeSentinel: sentinel, pollInterval: 60)
        var deliveredCounts: [Int] = []
        observer.start { deliveredCounts.append($0.changeCount) }
        observer.poll()

        switch disposition {
        case .privacyPaused:
            observer.setCapturePaused(true)
            observer.poll()
        case .ignored:
            observer.ignoreNextCopy()
            observer.poll()
        case .internalWrite:
            sentinel?.beginWrite(expectedChangeCount: 2)
        case .internalWriteWithPendingIgnore:
            observer.ignoreNextCopy()
            observer.poll()
            sentinel?.beginWrite(expectedChangeCount: 2)
        }

        reader.change = textChange(2, "changed while stopped")
        observer.stop()
        observer.poll()
        observer.start { deliveredCounts.append($0.changeCount) }
        observer.poll()

        if disposition == .privacyPaused {
            observer.setCapturePaused(false)
            observer.poll()
        }
        assertRecoveryAcknowledges(observer, count: 2)
        if disposition == .ignored || disposition == .internalWriteWithPendingIgnore {
            reader.change = textChange(3, "next copy after restart")
            observer.poll()
            XCTAssertEqual(deliveredCounts, [3])
        } else {
            XCTAssertTrue(deliveredCounts.isEmpty)
        }
        observer.stop()
    }

    private func makeReader() -> SteppingTestPasteboardReader {
        SteppingTestPasteboardReader(initial: textChange(1, "seed"))
    }

    private func textChange(_ count: Int, _ text: String) -> PasteboardChange {
        PasteboardChange(
            changeCount: count,
            items: [PasteboardItem(
                types: ["public.utf8-plain-text"],
                representations: ["public.utf8-plain-text": Data(text.utf8)]
            )]
        )
    }
}
