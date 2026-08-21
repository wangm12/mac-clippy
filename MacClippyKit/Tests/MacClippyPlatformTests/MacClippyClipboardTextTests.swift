import AppKit
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class MacClippyClipboardTextTests: XCTestCase {
    func testAttributedStringFromHTMLPreservesPlainText() {
        let attributed = MacClippyClipboardText.attributedString(from: .html("<b>Hi</b>"))

        XCTAssertEqual(attributed?.string.trimmingCharacters(in: .whitespacesAndNewlines), "Hi")
    }
}
