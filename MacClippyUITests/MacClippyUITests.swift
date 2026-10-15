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
            try showPanel(in: application)
            clickOnce("macClippy.searchFiltersButton", offset: offset, in: application)
            let filters = application.staticTexts["Filters"]
            XCTAssertTrue(filters.waitForExistence(timeout: 5),
                          "One filter click at \(offset) must open filters\n\(failureContext(application))")
            application.typeKey(.escape, modifierFlags: [])
            waitForDismissal(filters)

            try showPanel(in: application)
            clickOnce("macClippy.moreActionsButton", offset: offset, in: application)
            let menuItem = application.menuItems["New Pinboard…"]
            XCTAssertTrue(menuItem.waitForExistence(timeout: 5),
                          "One More click at \(offset) must open its menu\n\(failureContext(application))")
            application.typeKey(.escape, modifierFlags: [])
            waitForDismissal(menuItem)

            try showPanel(in: application)
            clickOnce("macClippy.settingsButton", offset: offset, in: application)
            let settings = application.windows.containing(
                .any, identifier: "macClippy.settings.sidebar.general").firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5),
                          "One Settings click at \(offset) must open settings\n\(failureContext(application))")
            settings.buttons[XCUIIdentifierCloseWindow].click()
            waitForDismissal(settings)
        }
    }

    func testNativeNavigationRespondsToOneClick() throws {
        try exerciseNativeNavigation(held: false)
    }

    func testNativeNavigationWithHeldClick() throws {
        try exerciseNativeNavigation(held: true)
    }

    private func exerciseNativeNavigation(held: Bool) throws {
        continueAfterFailure = false
        let application = try launchIsolatedApplication()
        defer { application.terminate() }
        try showPanel(in: application)
        let snippets = application.buttons["Snippets"]
        XCTAssertTrue(snippets.waitForExistence(timeout: 5))
        XCTAssertTrue(snippets.isEnabled)
        let coordinate = snippets.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5))
        coordinate.hover()
        if held {
            coordinate.click(forDuration: 0.15, thenDragTo: coordinate)
        } else {
            coordinate.click()
        }
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: snippets)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                       "One native navigation click must select Snippets\n\(failureContext(application))")
    }

    private func clickOnce(_ identifier: String, offset: CGVector, in application: XCUIApplication) {
        let control = application.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing chrome control: \(identifier)")
        XCTAssertTrue(control.isHittable, "Chrome control is not hittable: \(identifier)")
        XCTAssertTrue(control.isEnabled, "Chrome control is disabled: \(identifier)")
        XCTAssertEqual(control.frame.width, 36, accuracy: 1)
        XCTAssertEqual(control.frame.height, 36, accuracy: 1)
        // A coordinate click must hit the circle, including unpainted pixels;
        // accessibility performPress would not detect the original dead area.
        let coordinate = control.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.5)).withOffset(offset)
        coordinate.hover()
        if control.elementType == .menuButton {
            coordinate.click()
        } else {
            coordinate.click(forDuration: 0.15, thenDragTo: coordinate)
        }
    }

    private func waitForDismissal(_ element: XCUIElement) {
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    private func showPanel(in application: XCUIApplication) throws {
        // Coordinate clicks do not establish application activation. Make the
        // fixture's foreground state explicit before testing its hit regions.
        application.activate()
        _ = try controlRequest("panel-show")
    }

    private func failureContext(_ application: XCUIApplication) -> String {
        let metrics = (try? controlRequest("metrics")) ?? "Metrics unavailable"
        return "\(application.debugDescription)\n\(metrics)"
    }

    private func controlRequest(_ command: String) throws -> String {
        let environment = ProcessInfo.processInfo.environment
        let root = try XCTUnwrap(environment["MACCLIPPY_E2E_ROOT"])
        let runID = try XCTUnwrap(environment["MACCLIPPY_E2E_RUN_ID"])
        let driver = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/e2e/macclippy-phase5.py")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [driver.path, "request", "--root", root, "--run-id", runID,
                             "--control-command", command, "--socket-timeout", "30"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let response = String(data: data, encoding: .utf8) ?? "Invalid control response"
        XCTAssertEqual(process.terminationStatus, 0, response)
        return response
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
