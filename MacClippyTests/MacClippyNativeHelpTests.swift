import AppKit
import XCTest

@testable import MacClippy

final class MacClippyNativeHelpTests: XCTestCase {
    @MainActor
    func testHelpUsesSelectableNativeDocumentWithSearchAndResultKeyboardSteps() throws {
        let domain = "MacClippyNativeHelp-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let scrollView = MacClippyHelpWindow.makeContentView(defaults: defaults)
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertEqual(textView.accessibilityLabel(), "Shortcuts and search help")
        XCTAssertTrue(textView.string.contains("Return in search enters the results and keeps your query"))
        XCTAssertTrue(textView.string.contains("Return in results pastes it"))
        XCTAssertTrue(textView.string.contains("Double-click — Copy and close"))
        XCTAssertTrue(textView.string.contains("⌘C — Copy and keep the panel open"))
        XCTAssertTrue(textView.string.contains("Tab / Shift-Tab — Switch between search and results"))
        XCTAssertTrue(textView.string.contains("\"exact phrase\""))
        // Native text remains a single selectable document in either appearance,
        // rather than generating nested SwiftUI group/row AX children.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            textView.appearance = NSAppearance(named: appearance)
            XCTAssertEqual(textView.textStorage?.length, textView.string.utf16.count)
            XCTAssertNotNil(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        }
    }
}
