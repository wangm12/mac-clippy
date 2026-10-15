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

private final class MacClippyAsyncTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume() }
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
        let pasteboardEnvironment = MacClippyAppTestPasteboardEnvironment(label: "MacClippyOCRCancellation")
        let controlledRuntime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: controlledRoot),
            observer: pasteboardEnvironment.observer,
            pasteInjector: pasteboardEnvironment.injector,
            enableSnippetExpansion: false,
            preferencesDefaults: pasteboardEnvironment.preferencesDefaults,
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
        let pasteboardEnvironment = MacClippyAppTestPasteboardEnvironment(label: "MacClippyOCRByteBudget")
        let controlledRuntime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: controlledRoot),
            observer: pasteboardEnvironment.observer,
            pasteInjector: pasteboardEnvironment.injector,
            enableSnippetExpansion: false,
            preferencesDefaults: pasteboardEnvironment.preferencesDefaults,
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
        let pasteboardEnvironment = MacClippyAppTestPasteboardEnvironment(label: "MacClippyOCRGeneration")
        let controlledRuntime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: controlledRoot),
            observer: pasteboardEnvironment.observer,
            pasteInjector: pasteboardEnvironment.injector,
            enableSnippetExpansion: false,
            preferencesDefaults: pasteboardEnvironment.preferencesDefaults,
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

        let pasteboardEnvironment = MacClippyAppTestPasteboardEnvironment(label: "MacClippyOCRUpsertFailure")
        let controlledRuntime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: controlledRoot),
            observer: pasteboardEnvironment.observer,
            pasteInjector: pasteboardEnvironment.injector,
            enableSnippetExpansion: false,
            preferencesDefaults: pasteboardEnvironment.preferencesDefaults,
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

        let pasteboardEnvironment = MacClippyAppTestPasteboardEnvironment(label: "MacClippyOCRSearchSuccess")
        let controlledRuntime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: controlledRoot),
            observer: pasteboardEnvironment.observer,
            pasteInjector: pasteboardEnvironment.injector,
            enableSnippetExpansion: false,
            preferencesDefaults: pasteboardEnvironment.preferencesDefaults,
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
        let pasteboardEnvironment = MacClippyAppTestPasteboardEnvironment(label: "MacClippyOCRSchedule")
        let controlledRuntime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: controlledRoot),
            observer: pasteboardEnvironment.observer,
            pasteInjector: pasteboardEnvironment.injector,
            enableSnippetExpansion: false,
            preferencesDefaults: pasteboardEnvironment.preferencesDefaults,
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

        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(recognized.value, 0)
        XCTAssertEqual(controlledRuntime.pendingOCRJobsForTest(), 1)

        controlledRuntime.setOCRScheduleConditionsForTest(secondsSinceLastInput: 30, isLowPowerMode: true)
        controlledRuntime.flushDeferredOCRForTest()
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(recognized.value, 0)

        controlledRuntime.setOCRScheduleConditionsForTest(secondsSinceLastInput: 30, isLowPowerMode: false)
        controlledRuntime.flushDeferredOCRForTest()
        waitUntil(timeout: 3) {
            recognized.value == 1
        }
        XCTAssertEqual(recognized.value, 1)
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
        MacClippyTestWait.until(condition, timeout: timeout)
    }
}

extension MacClippyRuntimeOCRConcurrencyTests {
    func testStoppedOCRRetainsGlobalByteReservationUntilRecognizerReturns() throws {
        let controlledRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyOCRRetainedPayloadTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: controlledRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: controlledRoot) }

        let oldRecognitionStarted = DispatchSemaphore(value: 0)
        let oldRecognitionGate = MacClippyAsyncTestGate()
        let recognizer: @Sendable (Data) async throws -> String = { data in
            guard data.first == 1 else { return "fresh recognition" }
            oldRecognitionStarted.signal()
            await oldRecognitionGate.wait()
            return "stale recognition"
        }
        let environment = MacClippyAppTestPasteboardEnvironment(label: "MacClippyOCRRetainedPayload")
        let runtime = try makeOCRRuntime(
            root: controlledRoot,
            environment: environment,
            recognizer: recognizer
        )
        defer {
            oldRecognitionGate.open()
            runtime.stop()
            runtime.closeForTesting()
        }

        let record = try runtime.appendTestRecord(.text("source"))
        runtime.start()
        scheduleOCR(runtime, byte: 1, count: 40 * 1_024 * 1_024, recordID: record.id)
        XCTAssertEqual(oldRecognitionStarted.wait(timeout: .now() + 3), .success)

        runtime.stop()
        runtime.start()
        scheduleOCR(runtime, byte: 2, count: 32 * 1_024 * 1_024, recordID: record.id)
        XCTAssertEqual(runtime.pendingOCRJobsForTest(), 1)
        XCTAssertEqual(runtime.pendingOCRBytesForTest(), 40 * 1_024 * 1_024)

        oldRecognitionGate.open()
        waitUntil(timeout: 3) { runtime.pendingOCRJobsForTest() == 0 }
        scheduleOCR(runtime, byte: 2, count: 32 * 1_024 * 1_024, recordID: record.id)
        waitUntil(timeout: 3) { runtime.pendingOCRJobsForTest() == 0 }
        XCTAssertEqual(try runtime.history(limit: 10, query: "").first?.meta.ocrText, "fresh recognition")
    }

    private func makeOCRRuntime(
        root: URL,
        environment: MacClippyAppTestPasteboardEnvironment,
        recognizer: @escaping @Sendable (Data) async throws -> String
    ) throws -> MacClippyRuntime {
        try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: root),
            observer: environment.observer,
            pasteInjector: environment.injector,
            enableSnippetExpansion: false,
            preferencesDefaults: environment.preferencesDefaults,
            ocrRecognizer: recognizer
        )
    }

    private func scheduleOCR(
        _ runtime: MacClippyRuntime,
        byte: UInt8,
        count: Int,
        recordID: RecordID
    ) {
        runtime.scheduleOCRForTest(data: Data(repeating: byte, count: count), recordID: recordID)
    }
}
