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

private final class MacClippyImageReadOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (data: Data?, error: String?) = (nil, nil)

    func store(_ result: Result<Data, Error>) {
        lock.lock()
        switch result {
        case let .success(data): value = (data, nil)
        case let .failure(error): value = (nil, String(describing: error))
        }
        lock.unlock()
    }

    var snapshot: (data: Data?, error: String?) {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class MacClippyRuntimeConcurrencyTests: XCTestCase {
    private var tempRoot: URL!
    private var pasteboardEnvironment: MacClippyAppTestPasteboardEnvironment!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyRuntimeConcurrencyTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        pasteboardEnvironment = MacClippyAppTestPasteboardEnvironment(label: "MacClippyRuntimeConcurrency")
        runtime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: tempRoot),
            observer: pasteboardEnvironment.observer,
            pasteInjector: pasteboardEnvironment.injector,
            enableSnippetExpansion: false,
            preferencesDefaults: pasteboardEnvironment.preferencesDefaults
        )
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        pasteboardEnvironment = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testSelectAllReleasesStoreLockBetweenHistoryPages() throws {
        for index in 0..<257 {
            _ = try runtime.appendTestRecord(.text("page item \(index)"))
        }
        runtime.resetStoreLockMetricsForTesting()

        let ids = try runtime.historyRecordIDs(query: "")
        XCTAssertEqual(ids.count, 257)
        XCTAssertGreaterThanOrEqual(runtime.storeLockAcquisitionCount, 2)
    }

    func testImageDataReadsBlobOutsideStoreLock() throws {
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))
        runtime.resetStoreLockMetricsForTesting()

        let data = try runtime.imageData(id: image.id)
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(runtime.blobReadsWhileStoreLockHeld, 0)
        XCTAssertGreaterThan(runtime.storeLockAcquisitionCount, 0)
    }

    func testPreviewImageReadsBlobOutsideStoreLock() throws {
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))
        runtime.resetStoreLockMetricsForTesting()

        let preview = try runtime.preview(id: image.id)
        if case .image = preview {
            // Expected image payload.
        } else {
            XCTFail("expected image preview")
        }
        XCTAssertEqual(runtime.blobReadsWhileStoreLockHeld, 0)
    }

    func testImageDataHoldsLeaseBetweenRecordLookupAndBlobRead() throws {
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))
        let blobID = try imageBlobID(for: image.id)
        let sharedRuntime = try XCTUnwrap(runtime)
        try assertImageReadLeaseProtection(blobID: blobID) { [sharedRuntime] in
            try sharedRuntime.imageData(id: image.id)
        }
    }

    func testPreviewHoldsLeaseBetweenRecordLookupAndBlobRead() throws {
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))
        let blobID = try imageBlobID(for: image.id)
        let sharedRuntime = try XCTUnwrap(runtime)
        try assertImageReadLeaseProtection(blobID: blobID) { [sharedRuntime] in
            guard case .image = try sharedRuntime.preview(id: image.id) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return Data([1])
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

    private func imageBlobID(for id: RecordID) throws -> String {
        switch try runtime.clipboardStore.body(for: id) {
        case let .image(blobID, _, _), let .encryptedImage(blobID, _, _): return blobID
        case .text, .html, .rtf, .files: throw MacClippyStoreError.invalidStoredRecord
        }
    }

    private func assertImageReadLeaseProtection(
        blobID: String,
        read: @escaping @Sendable () throws -> Data
    ) throws {
        let leaseAcquired = DispatchSemaphore(value: 0)
        let resumeRead = DispatchSemaphore(value: 0)
        let completed = DispatchGroup()
        let outcome = MacClippyImageReadOutcome()
        runtime.afterImageBlobLeaseAcquiredForTesting = { _ in
            leaseAcquired.signal()
            _ = resumeRead.wait(timeout: .now() + 5)
        }
        defer {
            resumeRead.signal()
            runtime.afterImageBlobLeaseAcquiredForTesting = nil
        }

        completed.enter()
        DispatchQueue.global().async {
            outcome.store(Result { try read() })
            completed.leave()
        }

        XCTAssertEqual(leaseAcquired.wait(timeout: .now() + 3), .success)
        try runtime.blobStore.delete(id: blobID)
        XCTAssertTrue(try runtime.blobStore.containsChecked(id: blobID))
        resumeRead.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 3), .success)

        let result = outcome.snapshot
        XCTAssertNil(result.error)
        XCTAssertFalse(result.data?.isEmpty ?? true)
        XCTAssertTrue(try runtime.blobStore.containsChecked(id: blobID))
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

}
