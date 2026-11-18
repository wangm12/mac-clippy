import AppKit
import MacClippyPlatform
import XCTest

final class MacClippySearchResultRoutingTests: XCTestCase {
    func testFirstReturnAndTabOnlyMoveToResults() {
        for key: UInt16 in [36, 76, 48] {
            XCTAssertEqual(action(key, mode: .search), .focusResults)
            XCTAssertEqual(action(key, mode: .search, shift: true), .focusResults)
        }
        XCTAssertEqual(action(36, mode: .picker), .paste(plain: false))
        XCTAssertEqual(action(48, mode: .picker), .enterSearch)
    }

    func testIMEOwnsCandidateConfirmationAndSearchWhitespace() {
        for key: UInt16 in [36, 76, 48, 49, 53] {
            XCTAssertEqual(action(key, mode: .search, marked: true), .native)
        }
        XCTAssertEqual(action(49, mode: .search), .native)
    }

    func testHeldReturnCannotPasteOnTheHandoffRepeat() {
        let repeated = MacClippyDockKeyEvent.keyDown(
            keyCode: 36, characters: "\r", modifiers: [], isRepeat: true)
        XCTAssertEqual(
            MacClippyDockKeyRouterPolicy.action(
                for: repeated, mode: .search,
                hasCardFocus: true, hasMultipleSelection: false), .consume)
        XCTAssertEqual(
            MacClippyDockKeyRouterPolicy.action(
                for: repeated, mode: .picker,
                hasCardFocus: true, hasMultipleSelection: false), .consume)
    }

    private func action(
        _ key: UInt16, mode: MacClippyDockInteractionMode, shift: Bool = false, marked: Bool = false
    ) -> MacClippyDockKeyAction {
        MacClippyDockKeyRouterPolicy.action(
            for: .keyDown(keyCode: key, characters: nil, modifiers: shift ? [.shift] : [], isRepeat: false),
            mode: mode, hasCardFocus: true, hasMultipleSelection: false, hasMarkedText: marked
        )
    }
}
