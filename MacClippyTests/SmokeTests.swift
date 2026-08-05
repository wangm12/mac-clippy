import XCTest

import MacClippyCore
import MacClippyPlatform

final class SmokeTests: XCTestCase {
    func testApplicationPackageImports() {
        XCTAssertFalse(MacClippyCore.version.isEmpty)
        XCTAssertEqual(MacClippyPlatform.version, MacClippyCore.version)
    }
}
