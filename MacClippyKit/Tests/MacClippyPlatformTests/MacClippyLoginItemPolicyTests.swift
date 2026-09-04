import XCTest

@testable import MacClippyPlatform

final class MacClippyLoginItemPolicyTests: XCTestCase {
    func testDebugBuildMustNotRegister() {
        XCTAssertFalse(
            MacClippyLoginItemPolicy.shouldRegister(
                bundlePath: "/Applications/MacClippy.app",
                isDebugBuild: true
            )
        )
        XCTAssertNotNil(
            MacClippyLoginItemPolicy.warningMessage(
                bundlePath: "/Applications/MacClippy.app",
                isDebugBuild: true
            )
        )
    }

    func testDerivedDataAndBuildProductsMustNotRegister() {
        let derived = "/Users/me/Documents/github/personal-projects/mac-clippy/.build/DerivedData/Build/Products/Debug/MacClippy.app"
        XCTAssertFalse(
            MacClippyLoginItemPolicy.shouldRegister(bundlePath: derived, isDebugBuild: false)
        )
        XCTAssertNotNil(
            MacClippyLoginItemPolicy.warningMessage(bundlePath: derived, isDebugBuild: false)
        )
    }

    func testSignedApplicationsCopyMayRegister() {
        XCTAssertTrue(
            MacClippyLoginItemPolicy.shouldRegister(
                bundlePath: "/Applications/MacClippy.app",
                isDebugBuild: false
            )
        )
        XCTAssertNil(
            MacClippyLoginItemPolicy.warningMessage(
                bundlePath: "/Applications/MacClippy.app",
                isDebugBuild: false
            )
        )
    }

    func testNonApplicationsCopyWarnsWhenApplicationsCopyExists() {
        let message = MacClippyLoginItemPolicy.warningMessage(
            bundlePath: "/Users/me/MacClippy.app",
            isDebugBuild: false,
            applicationsCopyExists: true
        )
        XCTAssertEqual(
            message,
            "Another MacClippy is installed in Applications. Keep only one login item in System Settings."
        )
    }

    func testApplicationsCopyWarnsWhenAnotherBundleExists() {
        let message = MacClippyLoginItemPolicy.warningMessage(
            bundlePath: "/Applications/MacClippy.app",
            isDebugBuild: false,
            applicationsCopyExists: true,
            otherBundlePaths: [
                "/Users/me/Documents/github/personal-projects/mac-clippy/.build/DerivedData/Build/Products/Debug/MacClippy.app"
            ]
        )
        XCTAssertEqual(
            message,
            "Another MacClippy is installed. Keep only one login item in System Settings."
        )
    }
}
