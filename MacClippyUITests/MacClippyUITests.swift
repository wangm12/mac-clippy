import XCTest

@MainActor
final class MacClippyUITests: XCTestCase {
    func testApplicationLaunches() {
        let application = XCUIApplication()
        application.launch()

        XCTAssertTrue(
            application.wait(for: .runningForeground, timeout: 10),
            "Mac Clippy did not reach a running application state"
        )

        application.terminate()
    }
}
