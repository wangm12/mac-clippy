import MacClippyPlatform
import XCTest

final class MacClippyPinShortcutPolicyTests: XCTestCase {
    func testPinShortcutWorksForSingleFocusedPickerAndPreview() {
        for mode in [MacClippyDockInteractionMode.picker, .preview] {
            XCTAssertEqual(MacClippyDockKeyRouterPolicy.action(
                for: .keyDown(keyCode: 35, characters: "p", modifiers: .command, isRepeat: false),
                mode: mode, hasCardFocus: true, hasMultipleSelection: false), .pinSelection)
            XCTAssertEqual(MacClippyDockKeyRouterPolicy.action(
                for: .keyDown(keyCode: 35, characters: "p", modifiers: .command, isRepeat: false),
                mode: mode, hasCardFocus: false, hasMultipleSelection: false), mode == .preview ? .consume : .native)
        }
    }
}
