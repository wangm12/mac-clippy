import Foundation
import XCTest

@MainActor
final class MacClippyUITests: XCTestCase {
    func testApplicationLaunches() throws {
        let application = try launchIsolatedApplication()
        application.terminate()
    }

    func testChromeRespondsToOneClickAtCenterAndEdges() throws {
        continueAfterFailure = false
        let application = try launchIsolatedApplication()
        defer { application.terminate() }
        let offsets: [CGVector] = [.zero, .init(dx: -14, dy: 0), .init(dx: 14, dy: 0),
                                   .init(dx: 0, dy: -14), .init(dx: 0, dy: 14)]
        for offset in offsets {
            try showPanel()
            clickOnce("macClippy.searchFiltersButton", offset: offset, in: application)
            let filters = application.staticTexts["Filters"]
            XCTAssertTrue(filters.waitForExistence(timeout: 5), "One filter click at \(offset) must open filters")
            application.typeKey(.escape, modifierFlags: [])
            waitForDismissal(filters)

            try showPanel()
            clickOnce("macClippy.moreActionsButton", offset: offset, in: application)
            let menuItem = application.menuItems["New Pinboard…"]
            XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "One More click at \(offset) must open its menu")
            application.typeKey(.escape, modifierFlags: [])
            waitForDismissal(menuItem)

            try showPanel()
            clickOnce("macClippy.settingsButton", offset: offset, in: application)
            let settings = application.windows.containing(
                .any, identifier: "macClippy.settings.sidebar.general").firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5),
                          "One Settings click at \(offset) must open settings\n\(application.debugDescription)")
            settings.buttons[XCUIIdentifierCloseWindow].click()
            waitForDismissal(settings)
        }
    }

    private func clickOnce(_ identifier: String, offset: CGVector, in application: XCUIApplication) {
        let control = application.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing chrome control: \(identifier)")
        XCTAssertTrue(control.isHittable, "Chrome control is not hittable: \(identifier)")
        XCTAssertEqual(control.frame.width, 36, accuracy: 1)
        XCTAssertEqual(control.frame.height, 36, accuracy: 1)
        // A coordinate click must hit the circle, including unpainted pixels;
        // accessibility performPress would not detect the original dead area.
        control.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).withOffset(offset).click()
    }

    private func waitForDismissal(_ element: XCUIElement) {
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    private func showPanel() throws {
        let environment = ProcessInfo.processInfo.environment
        let root = try XCTUnwrap(environment["MACCLIPPY_E2E_ROOT"])
        let runID = try XCTUnwrap(environment["MACCLIPPY_E2E_RUN_ID"])
        let driver = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/e2e/macclippy-phase5.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [driver.path, "request", "--root", root, "--run-id", runID,
                             "--control-command", "panel-show", "--socket-timeout", "30"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(data: data, encoding: .utf8) ?? "Invalid control response")
    }

    private func launchIsolatedApplication() throws -> XCUIApplication {
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

        let application = XCUIApplication()
        application.launchEnvironment["MACCLIPPY_E2E_ROOT"] = root
        application.launchEnvironment["MACCLIPPY_E2E_RUN_ID"] = runID
        application.launchArguments.append("-XCTest")
        application.launch()

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
        return application
    }
}
