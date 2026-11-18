import Foundation
import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippyRuntimeSearchScaleTests: XCTestCase {
    private var root: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACCLIPPY_RUN_SCALE_TESTS"] == "1",
            "Set MACCLIPPY_RUN_SCALE_TESTS=1 to run the Runtime search fixture."
        )
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyRuntimeSearchScale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: root))
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    func testStructuredRuntimeSearchStaysPagedAtTenThousandRecords() throws {
        let recordCount = 10_000
        for index in 0..<recordCount {
            let text = "runtime scale body marker\(index)"
            let meta = try runtime.appendTestRecord(.text(text))
            try runtime.searchStore.upsert(id: meta.id, text: text)
        }

        let start = Date()
        let structuredResults = try runtime.history(limit: 16, query: "type:text")
        let structuredDuration = Date().timeIntervalSince(start)

        let bareAndStructuredStart = Date()
        let bareAndStructuredResults = try runtime.history(limit: 16, query: "scale type:text")
        let bareAndStructuredDuration = Date().timeIntervalSince(bareAndStructuredStart)
        let specificResults = try runtime.history(limit: 16, query: "marker9999 type:text")
        let noMatchStart = Date()
        let wrongKind = try runtime.historyPage(limit: 16, query: "scale type:image")
        let wrongApp = try runtime.historyPage(limit: 16, query: "scale app:missing")
        let noMatchDuration = Date().timeIntervalSince(noMatchStart)

        XCTAssertEqual(structuredResults.count, 16)
        XCTAssertEqual(bareAndStructuredResults.count, 16)
        XCTAssertEqual(specificResults.count, 1)
        XCTAssertTrue(specificResults.first?.meta.preview.contains("marker9999") == true)
        XCTAssertTrue(wrongKind.items.isEmpty)
        XCTAssertTrue(wrongApp.items.isEmpty)
        XCTAssertLessThan(noMatchDuration, 1, "no-match composite search must avoid repeated full FTS scans")
        XCTAssertEqual(try runtime.clipboardStore.databaseRowCount(), Int64(recordCount))
        XCTAssertLessThan(structuredDuration, 30, "structured Runtime search exceeded the scale budget")
        XCTAssertLessThan(
            bareAndStructuredDuration, 2, "Debug/TSan composite search must preserve an FTS MATCH scan"
        )

        XCTContext.runActivity(named: "MacClippy Runtime search scale timings") { activity in
            activity.add(XCTAttachment(string: "records=\(recordCount)"))
            activity.add(XCTAttachment(string: "structured_seconds=\(structuredDuration)"))
            activity.add(XCTAttachment(string: "bare_and_structured_seconds=\(bareAndStructuredDuration)"))
            activity.add(XCTAttachment(string: "no_match_composite_seconds=\(noMatchDuration)"))
        }
    }
}
