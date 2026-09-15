import AppKit
import XCTest

@testable import MacClippy

final class MacClippyDockFieldEditorTests: XCTestCase {
    @MainActor
    func testDockFieldEditorProvidesScreenCoordinatesForEmptyAndMarkedRanges() {
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 200, y: 300, width: 600, height: 100))
        let field = MacClippyIMESearchField(frame: NSRect(x: 50, y: 20, width: 300, height: 30))
        panel.contentView = field
        panel.makeKeyAndOrderFront(nil)
        defer {
            panel.animationBehavior = .none
            panel.orderOut(nil)
        }

        XCTAssertTrue(panel.makeFirstResponder(field))
        guard let editor = field.currentEditor() as? MacClippyDockFieldEditor else {
            return XCTFail("search field did not acquire MacClippyDockFieldEditor")
        }

        var actual = NSRange()
        let notFoundRect = editor.firstRect(
            forCharacterRange: NSRange(location: NSNotFound, length: 0),
            actualRange: &actual
        )
        XCTAssertGreaterThan(notFoundRect.origin.x, 0)
        XCTAssertGreaterThan(notFoundRect.origin.y, 0)
        XCTAssertGreaterThan(notFoundRect.size.height, 0)

        editor.setMarkedText(
            "c",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let markedNotFoundRect = editor.firstRect(
            forCharacterRange: NSRange(location: NSNotFound, length: 0),
            actualRange: &actual
        )
        XCTAssertGreaterThan(markedNotFoundRect.origin.x, 0)
        XCTAssertGreaterThan(markedNotFoundRect.origin.y, 0)
        XCTAssertGreaterThan(markedNotFoundRect.size.height, 0)

        let markedRangeRect = editor.firstRect(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualRange: &actual
        )
        XCTAssertGreaterThan(markedRangeRect.origin.x, 0)
        XCTAssertGreaterThan(markedRangeRect.origin.y, 0)
        XCTAssertGreaterThan(markedRangeRect.size.width, 0)
        XCTAssertGreaterThan(markedRangeRect.size.height, 0)
    }

    @MainActor
    func testDockFieldEditorProvidesScreenCoordinatesOnSecondaryDisplayWithNegativeOrigin() {
        let panel = MacClippyDockPanel(contentRect: NSRect(x: -1500, y: 300, width: 600, height: 100))
        let field = MacClippyIMESearchField(frame: NSRect(x: 50, y: 20, width: 300, height: 30))
        panel.contentView = field
        panel.makeKeyAndOrderFront(nil)
        defer {
            panel.animationBehavior = .none
            panel.orderOut(nil)
        }

        XCTAssertTrue(panel.makeFirstResponder(field))
        guard let editor = field.currentEditor() as? MacClippyDockFieldEditor else {
            return XCTFail("search field did not acquire MacClippyDockFieldEditor")
        }

        var actual = NSRange()
        let notFoundRect = editor.firstRect(
            forCharacterRange: NSRange(location: NSNotFound, length: 0),
            actualRange: &actual
        )
        // Screen coordinates must be anchored to the panel's negative X origin
        XCTAssertLessThan(notFoundRect.origin.x, 0)
        XCTAssertGreaterThan(notFoundRect.origin.y, 0)
        XCTAssertGreaterThan(notFoundRect.size.height, 0)
    }
}
