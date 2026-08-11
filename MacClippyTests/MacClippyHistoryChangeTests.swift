import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippyHistoryChangeTests: XCTestCase {
    private var tempRoot: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyHistoryChangeTests-\(UUID().uuidString)",
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

    @MainActor
    func testActiveDockReloadsWhenRuntimePublishesHistoryChange() throws {
        _ = try runtime.appendTestRecord(.text("before external copy"))

        let model = MacClippyDockModel(runtime: runtime)
        model.beginSession()
        model.reload()
        wait { model.historyItems.count == 1 }

        let newRecord = try runtime.appendTestRecord(.text("after external copy"))
        NotificationCenter.default.post(
            name: .macClippyHistoryDidChange,
            object: runtime
        )

        wait { model.historyItems.first?.id == newRecord.id }
        XCTAssertEqual(model.historyItems.first?.preview, "after external copy")
        model.endSession()
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
