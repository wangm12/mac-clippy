import XCTest

@testable import MacClippyCore

final class MacClippyPastePlainTextPolicyTests: XCTestCase {
    func testReturnPastesRichUnlessAlwaysPlainIsOn() {
        XCTAssertFalse(
            MacClippyPastePlainTextPolicy.shouldPastePlain(alwaysPlain: false, shiftHeld: false)
        )
        XCTAssertTrue(
            MacClippyPastePlainTextPolicy.shouldPastePlain(alwaysPlain: true, shiftHeld: false)
        )
    }

    func testShiftReturnInvertsThePlainTextDefault() {
        XCTAssertTrue(
            MacClippyPastePlainTextPolicy.shouldPastePlain(alwaysPlain: false, shiftHeld: true)
        )
        XCTAssertFalse(
            MacClippyPastePlainTextPolicy.shouldPastePlain(alwaysPlain: true, shiftHeld: true)
        )
    }
}
