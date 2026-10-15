import Foundation
import XCTest

@MainActor
final class MacClippyUITests: XCTestCase {
    func testApplicationLaunches() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["MACCLIPPY_E2E_ROOT"],
              let runID = environment["MACCLIPPY_E2E_RUN_ID"],
              UUID(uuidString: runID) != nil,
              FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: root)
                    .appendingPathComponent(".macclippy-e2e-root.json")
                    .path
              ) else {
            throw XCTSkip("Set up a marked E2E root before launching the isolated UI target.")
        }

        let application = XCUIApplication(bundleIdentifier: "com.macallyouneed.macclippy.e2e")
        application.launchEnvironment["MACCLIPPY_E2E_ROOT"] = root
        application.launchEnvironment["MACCLIPPY_E2E_RUN_ID"] = runID
        application.launchArguments.append("-XCTest")
        application.launch()
        defer { application.terminate() }

        // The isolated app starts as a background accessory. Foreground state
        // is optional until a test explicitly asks to show a native surface.
        let running = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "state == %d OR state == %d",
                XCUIApplication.State.runningForeground.rawValue,
                XCUIApplication.State.runningBackground.rawValue),
            object: application
        )
        let paths = ["control.sock", "databases/clipboard.sqlite", "databases/search.sqlite",
                     "databases/pinboards.sqlite", "databases/snippets.sqlite"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                paths.allSatisfy {
                    FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent($0).path)
                }
            }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [running, ready], timeout: 10), .completed,
            "Mac Clippy did not finish isolated startup (state: \(application.state.rawValue))")
    }
}
