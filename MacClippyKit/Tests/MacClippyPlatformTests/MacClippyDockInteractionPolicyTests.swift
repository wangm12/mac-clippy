import AppKit
import XCTest

@testable import MacClippyPlatform

final class MacClippyDockInteractionPolicyTests: XCTestCase {
    func testPickerSpaceOwnsPreviewEvenWhenAppKitFocusIsStale() {
        XCTAssertEqual(
            action(mode: .picker, keyCode: 49, hasCardFocus: true),
            .showPreview
        )
        XCTAssertEqual(
            action(mode: .picker, keyCode: 49, hasCardFocus: true, isRepeat: true),
            .consume
        )
    }

    func testPickerArrowsMoveIncludingRepeatedEvents() {
        XCTAssertEqual(
            action(mode: .picker, keyCode: 123, hasCardFocus: true),
            .moveFocus(.left)
        )
        XCTAssertEqual(
            action(mode: .picker, keyCode: 124, hasCardFocus: true),
            .moveFocus(.right)
        )
        XCTAssertEqual(
            action(mode: .picker, keyCode: 124, hasCardFocus: true, isRepeat: true),
            .moveFocus(.right)
        )
        XCTAssertEqual(
            action(mode: .picker, keyCode: 124, hasCardFocus: false),
            .consume
        )
    }

    func testPreviewSpaceAndArrowsStayInsideThePicker() {
        XCTAssertEqual(
            action(mode: .preview, keyCode: 49, hasCardFocus: true),
            .hidePreview
        )
        XCTAssertEqual(
            action(mode: .preview, keyCode: 49, hasCardFocus: true, isRepeat: true),
            .consume
        )
        XCTAssertEqual(
            action(mode: .preview, keyCode: 123, hasCardFocus: true),
            .moveFocus(.left)
        )
        XCTAssertEqual(
            action(mode: .preview, keyCode: 124, hasCardFocus: true, isRepeat: true),
            .moveFocus(.right)
        )
        XCTAssertEqual(
            keyUp(mode: .preview, keyCode: 124),
            .consume
        )
    }

    func testSearchEscapeClearsNonEmptyQueryFirst() {
        XCTAssertTrue(MacClippyDockSearchEscapePolicy.clearsQueryFirst("clip"))
        XCTAssertFalse(MacClippyDockSearchEscapePolicy.clearsQueryFirst("   "))
        XCTAssertFalse(MacClippyDockSearchEscapePolicy.clearsQueryFirst(""))
    }

    func testSearchModeLeavesTextEditingKeysNative() {
        XCTAssertEqual(action(mode: .search, keyCode: 49, hasCardFocus: true), .native)
        XCTAssertEqual(action(mode: .search, keyCode: 123, hasCardFocus: true), .native)
        XCTAssertEqual(action(mode: .search, keyCode: 51, hasCardFocus: true), .native)
        XCTAssertEqual(action(mode: .search, keyCode: 36, hasCardFocus: true), .native)
        XCTAssertEqual(action(mode: .search, keyCode: 53, hasCardFocus: true), .exitSearch)
    }

    func testReturnPastesInPickerAndPreview() {
        XCTAssertEqual(action(mode: .picker, keyCode: 36, hasCardFocus: true), .paste)
        XCTAssertEqual(action(mode: .preview, keyCode: 36, hasCardFocus: true), .paste)
        XCTAssertEqual(action(mode: .picker, keyCode: 36, hasCardFocus: false), .consume)
    }

    func testCommandCCopiesFromPreviewAndDetails() {
        XCTAssertEqual(action(mode: .preview, keyCode: 8, modifiers: .command, hasCardFocus: true), .copy)
        XCTAssertEqual(action(mode: .details, keyCode: 8, modifiers: .command, hasCardFocus: true), .copy)
        XCTAssertEqual(action(mode: .details, keyCode: 8, modifiers: .command, hasCardFocus: true, hasTextSelection: true), .native)
        XCTAssertEqual(action(mode: .preview, keyCode: 8, modifiers: .command), .consume)
    }

    func testCommandCopyIgnoresNonSemanticEventFlags() {
        XCTAssertTrue(
            MacClippyDockKeyRouterPolicy.isCommandCopy(
                keyCode: 8,
                modifiers: .init(rawValue: NSEvent.ModifierFlags.command.rawValue | 1 << 8)
            )
        )
        XCTAssertFalse(
            MacClippyDockKeyRouterPolicy.isCommandCopy(
                keyCode: 8,
                modifiers: [.command, .shift]
            )
        )
    }

    func testKeyUpIsConsumedByPickerSurfacesAndNativeInSearch() {
        XCTAssertEqual(keyUp(mode: .picker, keyCode: 49), .consume)
        XCTAssertEqual(keyUp(mode: .preview, keyCode: 124), .consume)
        XCTAssertEqual(
            MacClippyDockKeyRouterPolicy.action(
                for: .keyUp(keyCode: 0, modifiers: []),
                mode: .search,
                hasCardFocus: true,
                hasMultipleSelection: false
            ),
            .native
        )
    }

    func testSelectionShortcutsUseTheSharedRouter() {
        XCTAssertEqual(
            action(mode: .picker, keyCode: 0, modifiers: .command, hasCardFocus: true),
            .selectAll
        )
        XCTAssertEqual(
            action(mode: .picker, keyCode: 51, modifiers: .command, hasMultipleSelection: true),
            .deleteSelection
        )
        XCTAssertEqual(
            action(mode: .picker, keyCode: 51, modifiers: .command, hasCardFocus: true),
            .deleteSelection
        )
        XCTAssertEqual(
            action(mode: .picker, keyCode: 117, modifiers: .command, hasCardFocus: true),
            .deleteSelection
        )
        XCTAssertEqual(
            action(mode: .picker, keyCode: 51, modifiers: .command),
            .native
        )
        XCTAssertEqual(
            action(mode: .picker, keyCode: 35, modifiers: .command, hasMultipleSelection: true),
            .pinSelection
        )
        XCTAssertEqual(
            action(mode: .picker, keyCode: 124, modifiers: .shift, hasCardFocus: true),
            .extendRange(.right)
        )
    }

    func testPickerTypingAndBackspaceUpdateSearchWithoutTextFieldOwnership() {
        XCTAssertEqual(
            action(mode: .picker, keyCode: 0, characters: "a", hasCardFocus: true),
            .appendSearch("a")
        )
        XCTAssertEqual(
            action(mode: .picker, keyCode: 51, hasCardFocus: true),
            .deleteSearchCharacter
        )
    }

    func testPickerDoesNotBubbleNavigationWhenThereIsNoCard() {
        XCTAssertEqual(action(mode: .picker, keyCode: 49, hasCardFocus: false), .consume)
        XCTAssertEqual(action(mode: .picker, keyCode: 36, hasCardFocus: false), .consume)
        XCTAssertEqual(action(mode: .picker, keyCode: 123, hasCardFocus: false), .consume)
    }

    func testEscapeOrderingMatchesPickerSemantics() {
        XCTAssertEqual(
            action(mode: .picker, keyCode: 53, hasCardFocus: true, hasMultipleSelection: true),
            .clearSelection
        )
        XCTAssertEqual(
            action(mode: .picker, keyCode: 53, hasCardFocus: true),
            .closeDock
        )
        XCTAssertEqual(
            action(mode: .preview, keyCode: 53, hasCardFocus: true, hasMultipleSelection: true),
            .hidePreview
        )
    }

    func testCommandKEntersSearchFromAnyPickerSurface() {
        XCTAssertEqual(action(mode: .picker, keyCode: 40, modifiers: .command), .enterSearch)
        XCTAssertEqual(action(mode: .preview, keyCode: 40, modifiers: .command), .enterSearch)
    }

    func testDetailsShortcutTogglesWithoutBecomingPaste() {
        XCTAssertEqual(action(mode: .picker, keyCode: 9, modifiers: [.command, .option]), .showDetails)
        XCTAssertEqual(action(mode: .preview, keyCode: 9, modifiers: [.command, .option]), .showDetails)
        XCTAssertEqual(action(mode: .details, keyCode: 9, modifiers: [.command, .option]), .hideDetails)
        XCTAssertEqual(action(mode: .details, keyCode: 36, hasCardFocus: true), .paste)
        XCTAssertEqual(action(mode: .details, keyCode: 49, hasCardFocus: true), .showPreview)
        XCTAssertEqual(action(mode: .details, keyCode: 123, hasCardFocus: true), .moveFocus(.left))
        XCTAssertEqual(action(mode: .details, keyCode: 124, hasCardFocus: true), .moveFocus(.right))
        XCTAssertEqual(action(mode: .details, keyCode: 53, hasCardFocus: true), .hideDetails)
    }

    func testDetailsEditorLeavesNativeTypingUndoAndCancelsOnEscape() {
        XCTAssertEqual(
            action(mode: .details, keyCode: 0, characters: "a", hasCardFocus: true, detailsEditing: true),
            .native
        )
        XCTAssertEqual(
            action(mode: .details, keyCode: 51, hasCardFocus: true, detailsEditing: true),
            .native
        )
        XCTAssertEqual(
            action(mode: .details, keyCode: 53, hasCardFocus: true, detailsEditing: true),
            .cancelDetailsEdit
        )
        XCTAssertEqual(
            action(mode: .details, keyCode: 9, modifiers: [.command, .option], detailsEditing: true),
            .native
        )
        XCTAssertEqual(
            action(mode: .details, keyCode: 40, modifiers: .command, detailsEditing: true),
            .native
        )
    }

    func testModalOwnsEscapeButLeavesAllOtherEventsNative() {
        XCTAssertEqual(action(mode: .modal, keyCode: 53, hasCardFocus: true), .dismissModal)
        XCTAssertEqual(action(mode: .modal, keyCode: 124, hasCardFocus: true), .native)
        XCTAssertEqual(action(mode: .modal, keyCode: 0, characters: "a", hasCardFocus: true), .native)
        XCTAssertEqual(keyUp(mode: .modal, keyCode: 124), .native)
    }

    private func action(
        mode: MacClippyDockInteractionMode,
        keyCode: UInt16,
        characters: String? = nil,
        modifiers: NSEvent.ModifierFlags = [],
        hasCardFocus: Bool = false,
        hasMultipleSelection: Bool = false,
        isRepeat: Bool = false,
        detailsEditing: Bool = false,
        hasTextSelection: Bool = false
    ) -> MacClippyDockKeyAction {
        MacClippyDockKeyRouterPolicy.action(
            for: .keyDown(
                keyCode: keyCode,
                characters: characters,
                modifiers: modifiers,
                isRepeat: isRepeat
            ),
            mode: mode,
            hasCardFocus: hasCardFocus,
            hasMultipleSelection: hasMultipleSelection,
            detailsEditing: detailsEditing,
            hasTextSelection: hasTextSelection
        )
    }

    private func keyUp(
        mode: MacClippyDockInteractionMode,
        keyCode: UInt16
    ) -> MacClippyDockKeyAction {
        MacClippyDockKeyRouterPolicy.action(
            for: .keyUp(keyCode: keyCode, modifiers: []),
            mode: mode,
            hasCardFocus: true,
            hasMultipleSelection: false
        )
    }
}
