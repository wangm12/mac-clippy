import AppKit
import Foundation
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyRuntimeCaptureLifecycleTests: XCTestCase {
    @MainActor
    func testCaptureQueueRecoversLatestGenerationAfterCapacityReturns() throws {
        let root = try makeTemporaryRoot("CaptureBackpressure")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = MacClippyAppTestPasteboardEnvironment(label: "CaptureBackpressure")
        let runtime = try makeRuntime(root: root, environment: environment)
        defer {
            runtime.closeForTesting()
        }

        let gate = MacClippyCaptureCommitGate()
        runtime.setBeforeCaptureTransactionForTest { gate.blockFirstCommit() }
        runtime.start()
        runtime.observer.poll()
        var lastChangeCount = environment.pasteboard.changeCount

        for index in 0..<9 {
            environment.pasteboard.clearContents()
            XCTAssertTrue(
                environment.pasteboard.setString("queued capture \(index)", forType: .string)
            )
            let nextChangeCount = environment.pasteboard.changeCount
            XCTAssertGreaterThan(nextChangeCount, lastChangeCount)
            lastChangeCount = nextChangeCount
            runtime.observer.poll()
            if index == 0 {
                XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
            }
        }

        let blockedSnapshot = runtime.captureQueueAdmission.snapshot
        XCTAssertEqual(blockedSnapshot.outstandingJobs, 8)
        XCTAssertGreaterThanOrEqual(blockedSnapshot.droppedChangeCount, 1)

        gate.release()
        waitUntil(timeout: 8) {
            let snapshot = runtime.captureQueueAdmission.snapshot
            return snapshot.outstandingJobs == 0 && snapshot.recoveredChangeCount > 0
        }

        let snapshot = runtime.captureQueueAdmission.snapshot
        XCTAssertGreaterThan(snapshot.recoveredChangeCount, 0)
        let history = try runtime.history(limit: 20, query: "")
        XCTAssertTrue(
            history.contains { $0.preview == "queued capture 8" },
            "the current generation should be read again after capacity returns"
        )
    }

    @MainActor
    func testCapacityRecoveryDoesNotCapturePausedGenerationAcrossStopAndRestart() throws {
        let root = try makeTemporaryRoot("CapturePausedRestart")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = MacClippyAppTestPasteboardEnvironment(label: "CapturePausedRestart")
        let runtime = try makeRuntime(root: root, environment: environment)
        defer {
            runtime.stop()
            runtime.closeForTesting()
        }

        let gate = MacClippyCaptureCommitGate()
        runtime.setBeforeCaptureTransactionForTest { gate.blockFirstCommit() }
        runtime.start()
        runtime.observer.poll()
        fillCaptureQueue(runtime, environment: environment, gate: gate)

        runtime.observer.setCapturePaused(true)
        runtime.observer.poll()
        runtime.stop()
        runtime.observer.poll()
        writePasteboard("changed while stopped", environment: environment)
        runtime.start()
        runtime.observer.poll()

        gate.release()
        waitUntil(timeout: 8) {
            let snapshot = runtime.captureQueueAdmission.snapshot
            return snapshot.outstandingJobs == 0 && snapshot.currentGenerationReadRequestCount > 0
        }
        runtime.observer.setCapturePaused(false)
        runtime.observer.poll()
        runtime.drainCaptureQueueForTest()

        XCTAssertFalse(try runtime.history(limit: 20, query: "").contains {
            $0.preview == "changed while stopped"
        })
        XCTAssertEqual(runtime.captureQueueAdmission.snapshot.recoveredChangeCount, 0)
    }

    @MainActor
    func testStopReturnsWhileAdmittedCaptureCommitsAndFreshStartReadsIt() throws {
        let root = try makeTemporaryRoot("CaptureStopFence")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = MacClippyAppTestPasteboardEnvironment(label: "CaptureStopFence")
        let runtime = try makeRuntime(root: root, environment: environment)
        defer { runtime.closeForTesting() }

        let gate = MacClippyCaptureCommitGate()
        runtime.setBeforeCaptureTransactionForTest { gate.blockFirstCommit() }
        let noStaleNotification = expectation(description: "stopped capture does not publish a stale notification")
        noStaleNotification.isInverted = true
        let observerToken = NotificationCenter.default.addObserver(
            forName: .macClippyHistoryDidChange,
            object: runtime,
            queue: .main
        ) { _ in
            noStaleNotification.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observerToken) }

        runtime.start()
        runtime.observer.poll()
        let priorChangeCount = environment.pasteboard.changeCount
        environment.pasteboard.clearContents()
        XCTAssertTrue(environment.pasteboard.setString("admitted before stop", forType: .string))
        XCTAssertGreaterThan(environment.pasteboard.changeCount, priorChangeCount)
        runtime.observer.poll()
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)

        let stopStarted = Date()
        runtime.stop()
        XCTAssertLessThan(
            Date().timeIntervalSince(stopStarted),
            1,
            "ordinary stop must not drain a capture already inside its storage commit"
        )

        gate.release()
        runtime.drainCaptureQueueForTest()
        wait(for: [noStaleNotification], timeout: 0.2)
        XCTAssertTrue(try runtime.history(limit: 10, query: "").contains {
            $0.preview == "admitted before stop"
        })

        runtime.start()
        XCTAssertTrue(try runtime.history(limit: 10, query: "").contains {
            $0.preview == "admitted before stop"
        }, "a new lifecycle must observe the completed prior transaction")
        runtime.stop()
    }

    private func makeTemporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippy\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    private func fillCaptureQueue(
        _ runtime: MacClippyRuntime,
        environment: MacClippyAppTestPasteboardEnvironment,
        gate: MacClippyCaptureCommitGate
    ) {
        var lastChangeCount = environment.pasteboard.changeCount
        for index in 0..<9 {
            writePasteboard("queued capture \(index)", environment: environment)
            let nextChangeCount = environment.pasteboard.changeCount
            XCTAssertGreaterThan(nextChangeCount, lastChangeCount)
            lastChangeCount = nextChangeCount
            runtime.observer.poll()
            if index == 0 {
                XCTAssertEqual(gate.entered.wait(timeout: .now() + 3), .success)
            }
        }
        XCTAssertEqual(runtime.captureQueueAdmission.snapshot.outstandingJobs, 8)
    }

    private func writePasteboard(
        _ value: String,
        environment: MacClippyAppTestPasteboardEnvironment
    ) {
        environment.pasteboard.clearContents()
        XCTAssertTrue(environment.pasteboard.setString(value, forType: .string))
    }

    private func makeRuntime(
        root: URL,
        environment: MacClippyAppTestPasteboardEnvironment
    ) throws -> MacClippyRuntime {
        try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: root),
            observer: environment.observer,
            pasteInjector: environment.injector,
            enableSnippetExpansion: false,
            preferencesDefaults: environment.preferencesDefaults
        )
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("condition did not become true before timeout", file: file, line: line)
    }
}
