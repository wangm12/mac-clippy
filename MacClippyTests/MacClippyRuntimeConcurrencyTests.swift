import Foundation
import XCTest

@testable import MacClippy
import MacClippyCore

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

        for index in 0..<128 {
            group.enter()
            queue.async {
                if index.isMultiple(of: 2) {
                    _ = try? sharedRuntime.setCustomLabel(
                        id: record.id,
                        label: "label \(index)"
                    )
                } else {
                    _ = try? sharedRuntime.history(limit: 10, query: "concurrency")
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

        let entries = try sharedRuntime.history(limit: 10, query: "concurrency")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, record.id)
        XCTAssertNotNil(entries.first?.customLabel)
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
