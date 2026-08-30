import XCTest

import MacClippyCore

final class MacClippyBoundedUTF8Tests: XCTestCase {
    func testPrefixWalksBackFromAMidCodepointCut() {
        // U+4F60 你 is 3 UTF-8 bytes. A 4-byte cap lands inside the second
        // character. The old String(bytes:encoding:) path returned "".
        let text = "你你"
        let limited = MacClippySearchQuery.boundedUTF8Prefix(text, maxBytes: 4)
        XCTAssertEqual(limited, "你")
        XCTAssertFalse(limited.isEmpty)
    }

    func testPrefixKeepsTextThatFits() {
        XCTAssertEqual(MacClippySearchQuery.boundedUTF8Prefix("hello", maxBytes: 16), "hello")
    }

    func testPrefixIsEmptyWhenTheBudgetIsZero() {
        XCTAssertEqual(MacClippySearchQuery.boundedUTF8Prefix("hello", maxBytes: 0), "")
    }
}
