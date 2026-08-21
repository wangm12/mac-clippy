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

}
