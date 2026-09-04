import Foundation
import XCTest

@testable import MacClippy
import MacClippyCore

private final class MacClippyLockedOCRCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class MacClippyRuntimeOCRConcurrencyTests: XCTestCase {
    func testQueuedOCRCancellationDrainsPendingJobs() throws {
        let controlledRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyOCRCancellationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: controlledRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: controlledRoot) }

        let recognizer: @Sendable (Data) async throws -> String = { _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return "cancelled OCR"
        }
        let controlledRuntime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: controlledRoot),
            ocrRecognizer: recognizer
        )
        defer {
            controlledRuntime.stop()
            controlledRuntime.closeForTesting()
        }

        let record = try controlledRuntime.appendTestRecord(.text("source"))
        controlledRuntime.start()
        for _ in 0..<8 {
            controlledRuntime.scheduleOCRForTest(data: Data([1, 2, 3]), recordID: record.id)
        }
        controlledRuntime.stop()

        waitUntil(timeout: 3) {
            controlledRuntime.pendingOCRJobsForTest() == 0
        }
        XCTAssertEqual(controlledRuntime.pendingOCRJobsForTest(), 0)
        XCTAssertEqual(controlledRuntime.pendingOCRBytesForTest(), 0)
        let entry = try controlledRuntime.history(limit: 10, query: "").first
        XCTAssertNil(entry?.meta.ocrText, "cancelled OCR must not update clipboard metadata")
        XCTAssertTrue(
            try controlledRuntime.history(limit: 10, query: "cancelled OCR").isEmpty,
            "cancelled OCR must not create a stale search hit"
        )
    }

    func testOCRQueueEnforcesByteBudget() throws {
        let controlledRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyOCRByteBudgetTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: controlledRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: controlledRoot) }

        let recognizer: @Sendable (Data) async throws -> String = { _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            return "bounded OCR"
        }
        let controlledRuntime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: controlledRoot),
            ocrRecognizer: recognizer
        )
        defer {
            controlledRuntime.stop()
            controlledRuntime.closeForTesting()
        }

        let record = try controlledRuntime.appendTestRecord(.text("source"))
        controlledRuntime.start()
        let chunk = Data(repeating: 7, count: 16 * 1024 * 1024)
        for _ in 0..<8 {
            controlledRuntime.scheduleOCRForTest(data: chunk, recordID: record.id)
        }

        XCTAssertLessThanOrEqual(
            controlledRuntime.pendingOCRBytesForTest(),
            64 * 1024 * 1024
        )
        XCTAssertLessThanOrEqual(controlledRuntime.pendingOCRJobsForTest(), 8)
    }

    func testOCRFromPreviousRuntimeGenerationCannotWriteAfterRestart() throws {
        let controlledRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyOCRGenerationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: controlledRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: controlledRoot) }

        let started = DispatchSemaphore(value: 0)
        let recognizer: @Sendable (Data) async throws -> String = { _ in
            started.signal()
            // Ignore cancellation deliberately: the lifecycle token check,
            // not cooperative OCR cancellation alone, protects the database.
            try? await Task.sleep(nanoseconds: 150_000_000)
            return "stale OCR"
        }
        let controlledRuntime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: controlledRoot),
            ocrRecognizer: recognizer
        )
        defer {
            controlledRuntime.stop()
            controlledRuntime.closeForTesting()
        }

        let record = try controlledRuntime.appendTestRecord(.text("source"))
        controlledRuntime.start()
        controlledRuntime.scheduleOCRForTest(data: Data([1, 2, 3]), recordID: record.id)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

        controlledRuntime.stop()
        controlledRuntime.start()
        waitUntil(timeout: 3) {
            controlledRuntime.pendingOCRJobsForTest() == 0
        }

        let entry = try controlledRuntime.history(limit: 10, query: "").first
        XCTAssertNil(entry?.meta.ocrText)
    }

    func testOCRUpsertFailureDoesNotPersistUnsearchableTextAndMarksRepairNeeded() throws {
        let controlledRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyOCRUpsertFailureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: controlledRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: controlledRoot) }

        let controlledRuntime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: controlledRoot),
            ocrRecognizer: { _ in "unindexed recognized text" }
        )
        defer {
            controlledRuntime.stop()
            controlledRuntime.closeForTesting()
        }

        let record = try controlledRuntime.appendTestRecord(.text("source body"))
        XCTAssertNotNil(controlledRuntime.beginLifecycle())
        controlledRuntime.failNextOCRSearchUpsertForTest()
        controlledRuntime.scheduleOCRForTest(data: Data([1, 2, 3]), recordID: record.id)

        waitUntil(timeout: 3) {
            controlledRuntime.pendingOCRJobsForTest() == 0
        }

        let entry = try XCTUnwrap(controlledRuntime.history(limit: 10, query: "").first)
        XCTAssertNil(entry.meta.ocrText)
        XCTAssertTrue(try controlledRuntime.history(limit: 10, query: "unindexed recognized text").isEmpty)
        XCTAssertEqual(controlledRuntime.storageHealth()["search"]?.status, .repairable)
        XCTAssertTrue(controlledRuntime.storageHealth()["search"]?.issues.contains("fts-repair-needed") == true)
    }

    func testOCRSuccessPersistsTextAndUpdatesSearchIndex() throws {
        let controlledRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyOCRSearchSuccessTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: controlledRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: controlledRoot) }

        let controlledRuntime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: controlledRoot),
            ocrRecognizer: { _ in "searchable recognized text" }
        )
        defer {
            controlledRuntime.stop()
            controlledRuntime.closeForTesting()
        }

        let record = try controlledRuntime.appendTestRecord(.text("source body"))
        XCTAssertNotNil(controlledRuntime.beginLifecycle())
        controlledRuntime.scheduleOCRForTest(data: Data([1, 2, 3]), recordID: record.id)

        waitUntil(timeout: 3) {
            controlledRuntime.pendingOCRJobsForTest() == 0
        }

        let entry = try XCTUnwrap(controlledRuntime.history(limit: 10, query: "").first)
        XCTAssertEqual(entry.meta.ocrText, "searchable recognized text")
        XCTAssertEqual(
            try controlledRuntime.history(limit: 10, query: "searchable recognized text").map(\.id),
            [record.id]
        )
    }

    func testOCRDefersUntilIdleAndNotOnLowPower() throws {
        let controlledRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyOCRScheduleTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: controlledRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: controlledRoot) }

        let recognized = MacClippyLockedOCRCounter()
        let recognizer: @Sendable (Data) async throws -> String = { _ in
            recognized.increment()
            return "scheduled OCR"
        }
        let controlledRuntime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: controlledRoot),
            ocrRecognizer: recognizer
        )
        defer {
            controlledRuntime.stop()
            controlledRuntime.closeForTesting()
        }

        let record = try controlledRuntime.appendTestRecord(.text("source"))
        controlledRuntime.start()
        controlledRuntime.setOCRScheduleConditionsForTest(secondsSinceLastInput: 0.1, isLowPowerMode: false)
        controlledRuntime.enqueueScheduledOCRForTest(data: Data([1, 2, 3]), recordID: record.id)

        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(recognized.value, 0)
        XCTAssertEqual(controlledRuntime.pendingOCRJobsForTest(), 1)

        controlledRuntime.setOCRScheduleConditionsForTest(secondsSinceLastInput: 30, isLowPowerMode: true)
        controlledRuntime.flushDeferredOCRForTest()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(recognized.value, 0)

        controlledRuntime.setOCRScheduleConditionsForTest(secondsSinceLastInput: 30, isLowPowerMode: false)
        controlledRuntime.flushDeferredOCRForTest()
        waitUntil(timeout: 3) {
            recognized.value == 1
        }
        XCTAssertEqual(recognized.value, 1)
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
