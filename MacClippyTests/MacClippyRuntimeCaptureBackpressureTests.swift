import AppKit
import Foundation
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyCaptureCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldBlock = true
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    func blockFirstCommit() {
        lock.lock()
        let shouldBlock = self.shouldBlock
        self.shouldBlock = false
        lock.unlock()
        guard shouldBlock else { return }
        entered.signal()
        _ = resume.wait(timeout: .now() + 15)
    }

    func release() {
        resume.signal()
    }
}

private final class MacClippyRecoveryReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var didBlock = false
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func sourceAppBundleID() -> String? {
        lock.lock()
        let shouldBlock = armed && !didBlock
        if shouldBlock { didBlock = true }
        lock.unlock()
        guard shouldBlock else { return nil }
        entered.signal()
        _ = resume.wait(timeout: .now() + 10)
        return nil
    }
}

private final class MacClippyRecoveryReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var completionCounts: [Int?] = []
    private var admittedCounts: [Int] = []
    let completion = DispatchSemaphore(value: 0)
    let admitted = DispatchSemaphore(value: 0)

    func recordCompletion(_ changeCount: Int?) {
        lock.lock()
        completionCounts.append(changeCount)
        lock.unlock()
        completion.signal()
    }

    func recordAdmission(_ changeCount: Int) {
        lock.lock()
        admittedCounts.append(changeCount)
        lock.unlock()
        admitted.signal()
    }

    var completions: [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return completionCounts
    }

    var admissions: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return admittedCounts
    }
}

private struct MacClippyProductionRecoveryScenario {
    let pasteboard: NSPasteboard
    let sourceAppGate: MacClippyRecoveryReadGate
    let recorder: MacClippyRecoveryReadRecorder
    let admission: MacClippyCaptureQueueAdmission
    let observer: PasteboardObserver
    let reservations: [MacClippyPasteboardCaptureAdmission]
    let sevenMiB: Data
    let sixteenMiB: Data
}

final class MacClippyRuntimeCaptureBackpressureTests: XCTestCase {
    func testCaptureAdmissionEnforcesEstimatedRetainedByteBudget() {
        let admission = MacClippyCaptureQueueAdmission()
        let payload = Data(repeating: 7, count: 15 * 1_024 * 1_024)
        var tokens: [MacClippyPasteboardCaptureAdmission] = []

        for changeCount in 1...4 {
            let change = PasteboardChange(
                changeCount: changeCount,
                items: [PasteboardItem(
                    types: ["application/octet-stream"],
                    representations: ["application/octet-stream": payload]
                )]
            )
            guard let token = admission.admission(for: change) else {
                XCTFail("four 15 MiB changes should fit the estimated 256 MiB limit")
                return
            }
            tokens.append(token)
        }

        let rejected = PasteboardChange(
            changeCount: 5,
            items: [PasteboardItem(
                types: ["application/octet-stream"],
                representations: ["application/octet-stream": payload]
            )]
        )
        XCTAssertNil(admission.admission(for: rejected))
        XCTAssertEqual(admission.snapshot.outstandingJobs, 4)
        XCTAssertLessThanOrEqual(
            admission.snapshot.estimatedRetainedBytes,
            MacClippyCaptureQueueAdmission.maximumEstimatedRetainedBytes
        )
        let droppedCount = admission.snapshot.droppedChangeCount
        XCTAssertEqual(admission.snapshot.overloadErrorCount, droppedCount)
        XCTAssertEqual(admission.snapshot.notSavedCount, droppedCount)

        tokens.forEach { $0.finish(wasPersisted: false) }
        XCTAssertEqual(admission.snapshot.outstandingJobs, 0)
        XCTAssertEqual(admission.snapshot.estimatedRetainedBytes, 0)
        XCTAssertEqual(admission.snapshot.notSavedCount, droppedCount + tokens.count)
        XCTAssertEqual(admission.snapshot.persistFailureCount, 0)
        admission.recordPersistFailure()
        XCTAssertEqual(admission.snapshot.persistFailureCount, 1)
    }

    func testOlderRecoveryCompletionCannotEraseNewerOverloadCandidate() {
        let admission = MacClippyCaptureQueueAdmission()
        let sevenMiB = Data(repeating: 7, count: 7 * 1_024 * 1_024)
        let sixteenMiB = Data(repeating: 9, count: 16 * 1_024 * 1_024)
        var reservations: [MacClippyPasteboardCaptureAdmission] = []

        for changeCount in 1...8 {
            guard let reservation = admission.admission(for: makeSyntheticChange(
                changeCount: changeCount,
                data: sevenMiB
            )) else {
                return XCTFail("all eight seven MiB jobs should fit the byte budget")
            }
            reservations.append(reservation)
        }

        XCTAssertNil(admission.admission(for: makeSyntheticChange(changeCount: 11, data: sevenMiB)))
        reservations[0].finish(wasPersisted: true)
        XCTAssertTrue(admission.beginCurrentGenerationReadIfPossible())
        XCTAssertNil(admission.admission(for: makeSyntheticChange(changeCount: 12, data: sixteenMiB)))

        // The read began at generation 11, but its production materialization
        // observed generation 12 and admission retained 12 after overload.
        // A late completion carrying the poll-entry count must not erase it.
        admission.currentGenerationReadCompleted(changeCount: 11)
        reservations[1].finish(wasPersisted: true)
        XCTAssertTrue(admission.beginCurrentGenerationReadIfPossible())
        admission.currentGenerationReadCompleted(changeCount: nil)

        reservations.dropFirst(2).forEach { $0.finish(wasPersisted: true) }
        XCTAssertEqual(admission.snapshot.outstandingJobs, 0)
    }

    func testProductionObserverAndReaderRecoverNewGenerationAfterStalePollEntry() throws {
        let scenario = try makeProductionRecoveryScenario()
        let pasteboard = scenario.pasteboard
        let sourceAppGate = scenario.sourceAppGate
        let recorder = scenario.recorder
        let admission = scenario.admission
        let observer = scenario.observer
        let reservations = scenario.reservations
        let sevenMiB = scenario.sevenMiB
        let sixteenMiB = scenario.sixteenMiB
        defer {
            observer.stop()
            observer.poll()
            reservations.forEach { $0.finish(wasPersisted: true) }
        }
        observer.poll()

        XCTAssertTrue(writeSyntheticText(sevenMiB, to: pasteboard))
        let droppedGeneration = pasteboard.changeCount
        observer.poll()
        XCTAssertEqual(admission.snapshot.outstandingJobs, 8)
        XCTAssertEqual(admission.snapshot.droppedChangeCount, 1)

        sourceAppGate.arm()
        reservations[0].finish(wasPersisted: true)
        XCTAssertEqual(sourceAppGate.entered.wait(timeout: .now() + 3), .success)

        XCTAssertTrue(writeSyntheticText(sixteenMiB, to: pasteboard))
        let newerGeneration = pasteboard.changeCount
        XCTAssertGreaterThan(newerGeneration, droppedGeneration)
        sourceAppGate.resume.signal()

        XCTAssertEqual(recorder.completion.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(recorder.completions.count, 1)
        XCTAssertEqual(recorder.completions[0]!, newerGeneration)
        XCTAssertEqual(recorder.admissions, [])
        XCTAssertEqual(admission.snapshot.droppedChangeCount, 2)

        // The next reservation release requests a fresh current-generation
        // read. G12 must still be eligible and is accepted exactly once.
        reservations[1].finish(wasPersisted: true)
        XCTAssertEqual(recorder.completion.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(recorder.admitted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(recorder.completions.count, 2)
        XCTAssertEqual(recorder.completions[1]!, newerGeneration)
        XCTAssertEqual(recorder.admissions, [newerGeneration])
        XCTAssertEqual(admission.snapshot.recoveredChangeCount, 1)

        XCTAssertTrue(writeSyntheticText(Data("later external generation".utf8), to: pasteboard))
        let laterGeneration = pasteboard.changeCount
        XCTAssertGreaterThan(laterGeneration, newerGeneration)
        observer.poll()
        XCTAssertEqual(recorder.admitted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(recorder.admissions, [newerGeneration, laterGeneration])
    }

    private func makeProductionRecoveryScenario() throws -> MacClippyProductionRecoveryScenario {
        let pasteboard = NSPasteboard.withUniqueName()
        let sourceAppGate = MacClippyRecoveryReadGate()
        let recorder = MacClippyRecoveryReadRecorder()
        let admission = MacClippyCaptureQueueAdmission()
        let reader = MacClippySystemPasteboardReader(
            pasteboard: pasteboard,
            sourceAppBundleID: { sourceAppGate.sourceAppBundleID() }
        )
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 60,
            queue: DispatchQueue(label: "MacClippyCaptureRecoveryGenerationRace.\(UUID().uuidString)")
        )
        let sevenMiB = Data(repeating: 7, count: 7 * 1_024 * 1_024)
        let sixteenMiB = Data(repeating: 9, count: 16 * 1_024 * 1_024)
        let reservations = try (1...8).map { changeCount in
            try XCTUnwrap(admission.admission(for: makeSyntheticChange(
                changeCount: changeCount,
                data: sevenMiB
            )))
        }

        admission.setCapacityAvailableHandler { [weak admission, weak observer] in
            guard let admission, let observer,
                  admission.beginCurrentGenerationReadIfPossible() else {
                return
            }
            observer.requestCurrentGenerationRead { changeCount in
                admission.currentGenerationReadCompleted(changeCount: changeCount)
                recorder.recordCompletion(changeCount)
            }
        }
        observer.start(
            admissionHandler: { change in admission.admission(for: change) },
            admittedProjectionHandler: { change, _, reservation in
                recorder.recordAdmission(change.changeCount)
                reservation.finish(wasPersisted: true)
            }
        )
        return MacClippyProductionRecoveryScenario(
            pasteboard: pasteboard,
            sourceAppGate: sourceAppGate,
            recorder: recorder,
            admission: admission,
            observer: observer,
            reservations: reservations,
            sevenMiB: sevenMiB,
            sixteenMiB: sixteenMiB
        )
    }

    private func makeSyntheticChange(changeCount: Int, data: Data) -> PasteboardChange {
        PasteboardChange(
            changeCount: changeCount,
            items: [PasteboardItem(
                types: ["application/octet-stream"],
                representations: ["application/octet-stream": data]
            )]
        )
    }

    private func writeSyntheticText(_ data: Data, to pasteboard: NSPasteboard) -> Bool {
        guard let string = String(data: data, encoding: .utf8) else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(string, forType: .string)
    }

}
