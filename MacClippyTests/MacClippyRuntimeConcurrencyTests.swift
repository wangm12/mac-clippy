import Foundation
import XCTest

@testable import MacClippy
import MacClippyCore

private final class MacClippyConcurrencyErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ error: Error) {
        lock.lock()
        messages.append(String(describing: error))
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

final class MacClippyRuntimeConcurrencyTests: XCTestCase {
    private var tempRoot: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyRuntimeConcurrencyTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: tempRoot))
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testConcurrentHistoryAndLabelAccessUsesRuntimeStoreBoundary() throws {
        let record = try runtime.appendTestRecord(.text("concurrency body"))
        let sharedRuntime = runtime!
        let queue = DispatchQueue(label: "MacClippyRuntimeConcurrencyTests", attributes: .concurrent)
        let group = DispatchGroup()
        let errors = MacClippyConcurrencyErrorCollector()

        for index in 0..<128 {
            group.enter()
            queue.async {
                if index.isMultiple(of: 2) {
                    do {
                        _ = try sharedRuntime.setCustomLabel(
                            id: record.id,
                            label: "label \(index)"
                        )
                    } catch {
                        errors.append(error)
                    }
                } else {
                    do {
                        _ = try sharedRuntime.history(limit: 10, query: "concurrency")
                    } catch {
                        errors.append(error)
                    }
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(errors.snapshot.isEmpty, errors.snapshot.joined(separator: "; "))

        let entries = try sharedRuntime.history(limit: 10, query: "concurrency")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, record.id)
        XCTAssertNotNil(entries.first?.customLabel)
    }

    func testHistoryProjectionCacheIsReusedDuringContentKindValidation() throws {
        let record = try runtime.appendTestRecord(.text("cached projection body"))
        let metadata = try XCTUnwrap(runtime.clipboardStore.metas(for: [record.id]).first)
        let cached = MacClippyHistoryEntry(
            meta: metadata,
            contentKind: .text,
            preview: "cached projection"
        )
        runtime.historyEntryCache.setObject(
            MacClippyHistoryEntryCacheBox(cached),
            forKey: runtime.cacheKey(for: metadata),
            cost: runtime.historyEntryCacheCost(cached)
        )

        let entries = try runtime.history(limit: 10, query: "")

        XCTAssertEqual(entries.first?.preview, "cached projection")
    }

    func testHistoryProjectionCacheMismatchForcesBodyValidation() throws {
        let record = try runtime.appendTestRecord(.text("validated projection body"))
        let metadata = try XCTUnwrap(runtime.clipboardStore.metas(for: [record.id]).first)
        let mismatched = MacClippyHistoryEntry(
            meta: metadata,
            contentKind: .image,
            preview: "stale projection"
        )
        runtime.historyEntryCache.setObject(
            MacClippyHistoryEntryCacheBox(mismatched),
            forKey: runtime.cacheKey(for: metadata),
            cost: runtime.historyEntryCacheCost(mismatched)
        )

        let entries = try runtime.history(limit: 10, query: "")

        XCTAssertEqual(entries.first?.contentKind, .text)
        XCTAssertNotEqual(entries.first?.preview, "stale projection")
    }

    @MainActor
    func testRuntimeStartStopIsIdempotentAcrossRepeatedLifecycleTransitions() throws {
        runtime.start()
        runtime.start()
        XCTAssertTrue(runtime.isRunning)

        runtime.stop()
        runtime.stop()
        XCTAssertFalse(runtime.isRunning)

        runtime.start()
        XCTAssertTrue(runtime.isRunning)
        runtime.stop()
        XCTAssertFalse(runtime.isRunning)
    }

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

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
