import XCTest

@testable import MacClippyCore
@testable import MacClippyPlatform

final class MacClippyDockSearchQueryWritePolicyTests: XCTestCase {
    func testPickerTypedCharacterSurvivesSpuriousEmptyFieldWrite() {
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.committedQuery(
                current: "d",
                incoming: "",
                allowEmptyOverwrite: false
            ),
            "d"
        )
    }

    func testExplicitEmptyWriteClearsTheQuery() {
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.committedQuery(
                current: "d",
                incoming: "",
                allowEmptyOverwrite: true
            ),
            ""
        )
    }

    func testNonEmptyEditsAlwaysCommit() {
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.committedQuery(
                current: "d",
                incoming: "da",
                allowEmptyOverwrite: false
            ),
            "da"
        )
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.committedQuery(
                current: "",
                incoming: "d",
                allowEmptyOverwrite: false
            ),
            "d"
        )
    }

    func testEmptyOverwriteStaysBlockedUntilUserEditOrClear() {
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.allowsEmptyOverwrite(
                currently: false,
                after: .programmaticQueryWrite
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.allowsEmptyOverwrite(
                currently: false,
                after: .mainQueueTurn
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.allowsEmptyOverwrite(
                currently: false,
                after: .searchFieldFocused
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.allowsEmptyOverwrite(
                currently: false,
                after: .historyReloadApplied
            )
        )
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.allowsEmptyOverwrite(
                currently: false,
                after: .userKeyEvent
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.allowsEmptyOverwrite(
                currently: true,
                after: .nonEmptyFieldCommit
            )
        )
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.allowsEmptyOverwrite(
                currently: false,
                after: .explicitClear
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.allowsEmptyOverwrite(
                currently: true,
                after: .sessionBegan
            )
        )
    }

    func testRejectedEmptyWriteKeepsTheCommittedDisplayText() {
        let committed = MacClippyDockSearchQueryWritePolicy.committedQuery(
            current: "d",
            incoming: "",
            allowEmptyOverwrite: false
        )
        XCTAssertEqual(committed, "d")
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.displayedSearchText(committedQuery: committed),
            "d"
        )
    }

    func testDisplayedSearchTextOmitsSmartListTokens() {
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.displayedSearchText(
                committedQuery: "type:url",
                excludingTokens: ["type:url", "type:image"]
            ),
            ""
        )
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.displayedSearchText(
                committedQuery: "invoice type:image",
                excludingTokens: ["type:url", "type:image"]
            ),
            "invoice"
        )
    }

    func testFieldSyncOfStrippedSmartListQueryDoesNotClearTheFilter() {
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.committedQuery(
                current: "type:url",
                incoming: "",
                allowEmptyOverwrite: true,
                preservedTokens: ["type:url", "type:image"]
            ),
            "type:url"
        )
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.committedQuery(
                current: "invoice type:url",
                incoming: "invoice",
                allowEmptyOverwrite: false,
                preservedTokens: ["type:url", "type:image"]
            ),
            "invoice type:url"
        )
    }

    func testStaleSmartListResidueDoesNotOverwriteAnEmptyDisplayQuery() {
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.committedQuery(
                current: "",
                incoming: "typeimage",
                allowEmptyOverwrite: true,
                preservedTokens: ["type:url", "type:image"]
            ),
            ""
        )
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.committedQuery(
                current: "",
                incoming: "type:image",
                allowEmptyOverwrite: true,
                preservedTokens: ["type:url", "type:image"]
            ),
            ""
        )
    }

    func testStaleStrippedResidueDoesNotMergeOntoASmartList() {
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.committedQuery(
                current: "type:url",
                incoming: "typeimage",
                allowEmptyOverwrite: false,
                preservedTokens: ["type:url", "type:image"]
            ),
            "type:url"
        )
    }

    func testTypingKeepsAnActiveSmartListToken() {
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.committedQuery(
                current: "type:image",
                incoming: "notes",
                allowEmptyOverwrite: false,
                preservedTokens: ["type:url", "type:image"]
            ),
            "notes type:image"
        )
    }

    func testFilterChipsAreNotTextFieldSiblings() {
        XCTAssertFalse(MacClippyDockSearchQueryWritePolicy.placesFilterChipsBesideSearchField())
    }

    func testMountedChipsKeepAppliedAndSuggestionIdentity() {
        let applied = [
            MacClippySearchFilterChip(token: "type:text", title: "Text", isSuggestion: false),
        ]
        let suggestions = MacClippySearchFilterChipPolicy.suggestedCatalog.filter { $0.token != "type:text" }
        let mounted = MacClippyDockSearchQueryWritePolicy.mountedSearchFilterChips(
            applied: applied,
            suggestions: suggestions
        )
        XCTAssertEqual(mounted.map(\.id), (applied + suggestions).map(\.id))
    }

    func testMountedChipsOmitTokensAlreadyRepresentedBySmartLists() {
        let applied = [
            MacClippySearchFilterChip(token: "type:url", title: "URL", isSuggestion: false),
            MacClippySearchFilterChip(token: "has:ocr", title: "Has OCR", isSuggestion: false),
        ]
        let suggestions = [
            MacClippySearchFilterChip(token: "type:image", title: "Image", isSuggestion: true),
            MacClippySearchFilterChip(token: "type:text", title: "Text", isSuggestion: true),
        ]
        let mounted = MacClippyDockSearchQueryWritePolicy.mountedSearchFilterChips(
            applied: applied,
            suggestions: suggestions,
            excludingTokens: ["type:url", "type:image"]
        )
        XCTAssertEqual(mounted.map(\.token), ["has:ocr", "type:text"])
    }

    func testChipRowVisibilityUsesFocusOrAppliedChips() {
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.isChipRowVisible(
                isSearchFocused: true,
                hasAppliedChips: false
            )
        )
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.isChipRowVisible(
                isSearchFocused: false,
                hasAppliedChips: true
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.isChipRowVisible(
                isSearchFocused: false,
                hasAppliedChips: false
            )
        )
    }

    func testClearButtonVisibilityFollowsQuery() {
        XCTAssertTrue(MacClippyDockSearchQueryWritePolicy.isClearButtonVisible(hasQuery: true))
        XCTAssertFalse(MacClippyDockSearchQueryWritePolicy.isClearButtonVisible(hasQuery: false))
    }

    func testProgrammaticFocusPlacesCaretAtEndWithoutSelectingTheTypedQuery() {
        XCTAssertFalse(MacClippyDockSearchQueryWritePolicy.selectsTypedQueryOnProgrammaticFocus())

        let ascii = MacClippyDockSearchQueryWritePolicy.caretAfterProgrammaticFocus(query: "d")
        XCTAssertEqual(ascii.utf16Location, 1)
        XCTAssertEqual(ascii.utf16Length, 0)

        let multibyte = MacClippyDockSearchQueryWritePolicy.caretAfterProgrammaticFocus(query: "你好")
        XCTAssertEqual(multibyte.utf16Location, 2)
        XCTAssertEqual(multibyte.utf16Length, 0)

        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.selectedRange(
                caret: ascii,
                queryUTF16Length: 1
            ),
            NSRange(location: 1, length: 0)
        )
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.selectedRange(
                caret: MacClippyDockSearchFieldCaret(utf16Location: 8, utf16Length: 2),
                queryUTF16Length: 1
            ),
            NSRange(location: 1, length: 0)
        )
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.shouldCollapseFullSelection(
                selectedUTF16Length: 1,
                queryUTF16Length: 1
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldCollapseFullSelection(
                selectedUTF16Length: 0,
                queryUTF16Length: 1
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldCollapseFullSelection(
                selectedUTF16Length: 0,
                queryUTF16Length: 0
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldCollapseFullSelection(
                selectedUTF16Length: 1,
                queryUTF16Length: 1,
                hasMarkedText: true
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldApplyProgrammaticCaret(hasMarkedText: true)
        )
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.shouldApplyProgrammaticCaret(hasMarkedText: false)
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldCollapseCaretAfterProgrammaticFocus(query: "")
        )
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.shouldCollapseCaretAfterProgrammaticFocus(query: "d")
        )
    }

    func testAppKitFieldEditorOwnsCompositionAndOnlyPublishesCommittedText() {
        XCTAssertTrue(MacClippyDockSearchQueryWritePolicy.usesAppKitFieldEditorForSearch())
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldPublishFieldEditorString(hasMarkedText: true)
        )
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.shouldPublishFieldEditorString(hasMarkedText: false)
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldApplyExternalStringToFieldEditor(
                hasMarkedText: true,
                incoming: "ce",
                current: ""
            )
        )
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.shouldApplyExternalStringToFieldEditor(
                hasMarkedText: false,
                incoming: "测试",
                current: ""
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldApplyExternalStringToFieldEditor(
                hasMarkedText: false,
                incoming: "测试",
                current: "测试"
            )
        )
    }

    func testNativeFieldOnlyBlocksExternalWritesDuringMarkedText() {
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldApplyExternalStringToFieldEditor(
                hasMarkedText: true,
                incoming: "",
                current: "ce"
            )
        )
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.shouldApplyExternalStringToFieldEditor(
                hasMarkedText: false,
                incoming: "",
                current: "committed query",
                isEditing: true,
                programmaticSync: false
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldApplyExternalStringToFieldEditor(
                hasMarkedText: false,
                incoming: "same",
                current: "same"
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldApplyExternalStringToFieldEditor(
                hasMarkedText: false,
                incoming: "",
                current: "",
                programmaticSync: true
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldMakeSearchFieldFirstResponder(
                wantsFocus: true,
                isAlreadyEditing: false,
                hasMarkedText: true
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldMakeSearchFieldFirstResponder(
                wantsFocus: true,
                isAlreadyEditing: true,
                hasMarkedText: false
            )
        )
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.shouldMakeSearchFieldFirstResponder(
                wantsFocus: true,
                isAlreadyEditing: false,
                hasMarkedText: false
            )
        )
    }

    func testMarkedTextDoesNotRewriteTheFieldDisplay() {
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldSyncDisplayedSearchText(hasMarkedText: true)
        )
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.shouldSyncDisplayedSearchText(hasMarkedText: false)
        )
    }

    func testMarkedTextPreeditDoesNotCommitIntoTheSearchQuery() {
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.committedQuery(
                current: "",
                incoming: "ce",
                allowEmptyOverwrite: false,
                hasMarkedText: true
            ),
            ""
        )
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.committedQuery(
                current: "已有",
                incoming: "已有ce",
                allowEmptyOverwrite: false,
                hasMarkedText: true
            ),
            "已有"
        )
    }

    func testMarkedTextEmptyWriteDoesNotWipeTheCommittedQuery() {
        XCTAssertEqual(
            MacClippyDockSearchQueryWritePolicy.committedQuery(
                current: "你好",
                incoming: "",
                allowEmptyOverwrite: false,
                hasMarkedText: true
            ),
            "你好"
        )
    }

    func testCaretCollapseUsesOneApplyAndOneRetry() {
        XCTAssertEqual(MacClippyDockSearchQueryWritePolicy.caretCollapseApplyCount, 2)
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.shouldRefreshCaretHost(
                queryChanged: false,
                collapseTokenChanged: false
            )
        )
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.shouldRefreshCaretHost(
                queryChanged: true,
                collapseTokenChanged: false
            )
        )
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.shouldRefreshCaretHost(
                queryChanged: false,
                collapseTokenChanged: true
            )
        )
    }

    func testLeavingSearchClearsTheCommittedQuery() {
        XCTAssertTrue(MacClippyDockSearchQueryWritePolicy.shouldClearQueryWhenLeavingSearch())
    }

    func testSearchFieldClearKeysUnlockEmptyOverwrite() {
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.notesSearchFieldUserEdit(
                isSearchMode: true,
                isDeleteKey: true,
                isCommandA: false
            )
        )
        XCTAssertTrue(
            MacClippyDockSearchQueryWritePolicy.notesSearchFieldUserEdit(
                isSearchMode: true,
                isDeleteKey: false,
                isCommandA: true
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.notesSearchFieldUserEdit(
                isSearchMode: false,
                isDeleteKey: false,
                isCommandA: true
            )
        )
        XCTAssertFalse(
            MacClippyDockSearchQueryWritePolicy.notesSearchFieldUserEdit(
                isSearchMode: true,
                isDeleteKey: false,
                isCommandA: false
            )
        )
    }
}
