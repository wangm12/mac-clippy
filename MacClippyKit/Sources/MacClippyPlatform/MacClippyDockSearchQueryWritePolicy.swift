import Foundation

import MacClippyCore

/// Picker-mode and focused-field typing both commit into `query`. Focusing or
/// remounting the AppKit field can then emit "" and wipe that character.
/// Reject empty overwrites until Backspace/Delete or an explicit clear. Keep
/// filter chips out of the field's HStack.
public enum MacClippyDockSearchEmptyOverwriteEvent: Equatable, Sendable {
    case programmaticQueryWrite
    case mainQueueTurn
    case searchFieldFocused
    case historyReloadApplied
    case userKeyEvent
    case nonEmptyFieldCommit
    case explicitClear
    case sessionBegan
}

public enum MacClippyDockSearchQueryWritePolicy {
    public static let reservedChipRowWidth: CGFloat = 220

    public static func committedQuery(
        current: String,
        incoming: String,
        allowEmptyOverwrite: Bool,
        hasMarkedText: Bool = false,
        preservedTokens: Set<String> = []
    ) -> String {
        if hasMarkedText {
            return current
        }
        let visibleCurrent = displayedSearchText(
            committedQuery: current,
            excludingTokens: preservedTokens
        )
        if incoming == visibleCurrent {
            return current
        }
        if visibleCurrent.isEmpty, MacClippySmartListPolicy.isFieldResidue(incoming) {
            return current
        }
        if incoming.isEmpty, !current.isEmpty, !allowEmptyOverwrite {
            return current
        }
        return mergingPreservedTokens(
            incoming,
            currentlyIn: current,
            preservedTokens: preservedTokens
        )
    }

    public static func mergingPreservedTokens(
        _ visible: String,
        currentlyIn current: String,
        preservedTokens: Set<String>
    ) -> String {
        let active = Set(
            MacClippySearchFilterChipPolicy.chips(
                from: MacClippySearchGrammar.parse(current)
            ).map(\.token)
        )
        return preservedTokens.sorted().reduce(visible) { partial, token in
            guard active.contains(token) else { return partial }
            return MacClippySearchFilterChipPolicy.appending(token: token, to: partial)
        }
    }

    public static func allowsEmptyOverwrite(
        currently: Bool,
        after event: MacClippyDockSearchEmptyOverwriteEvent
    ) -> Bool {
        switch event {
        case .programmaticQueryWrite:
            return false
        case .mainQueueTurn, .searchFieldFocused, .historyReloadApplied:
            return currently
        case .nonEmptyFieldCommit, .sessionBegan:
            return false
        case .userKeyEvent, .explicitClear:
            return true
        }
    }

    public static func placesFilterChipsBesideSearchField() -> Bool {
        false
    }

    /// URL/Image already have rail pills. Mounting a second chip for the
    /// same token inserts a removable "URL ×" between search and All and
    /// shifts the whole tag row.
    public static func mountedSearchFilterChips(
        applied: [MacClippySearchFilterChip],
        suggestions: [MacClippySearchFilterChip],
        excludingTokens: Set<String> = []
    ) -> [MacClippySearchFilterChip] {
        (applied + suggestions).filter { !excludingTokens.contains($0.token) }
    }

    public static func isChipRowVisible(
        isSearchFocused: Bool,
        hasAppliedChips: Bool
    ) -> Bool {
        isSearchFocused || hasAppliedChips
    }

    public static func chipRowMaxWidth(isVisible: Bool) -> CGFloat {
        isVisible ? reservedChipRowWidth : 0
    }

    public static func isClearButtonVisible(hasQuery: Bool) -> Bool {
        hasQuery
    }

    /// The AppKit field can keep an empty string after a rejected `""` write.
    /// Always show the committed query so the user still sees the typed text.
    /// Smart-list tokens already have rail pills. Showing them in the field
    /// makes All look like a leftover `type:image` search and empties History
    /// when that text is committed back as a bare term.
    public static func displayedSearchText(
        committedQuery: String,
        excludingTokens: Set<String> = []
    ) -> String {
        excludingTokens
            .sorted()
            .reduce(committedQuery) { partial, token in
                MacClippySearchFilterChipPolicy.removing(token: token, from: partial)
            }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Picker-mode typing focuses the field after the first character is
    /// already in `query`. AppKit then selects that character, so the next
    /// key replaces it. Collapse to an insertion point at the end instead.
    public static func selectsTypedQueryOnProgrammaticFocus() -> Bool {
        false
    }

    public static func caretAfterProgrammaticFocus(query: String) -> MacClippyDockSearchFieldCaret {
        MacClippyDockSearchFieldCaret(utf16Location: (query as NSString).length)
    }

    public static func selectedRange(
        caret: MacClippyDockSearchFieldCaret,
        queryUTF16Length: Int
    ) -> NSRange {
        let length = max(queryUTF16Length, 0)
        let location = min(max(caret.utf16Location, 0), length)
        let remaining = length - location
        return NSRange(
            location: location,
            length: min(max(caret.utf16Length, 0), remaining)
        )
    }

    public static func shouldCollapseFullSelection(
        selectedUTF16Length: Int,
        queryUTF16Length: Int,
        hasMarkedText: Bool = false
    ) -> Bool {
        if hasMarkedText { return false }
        return queryUTF16Length > 0 && selectedUTF16Length == queryUTF16Length
    }

    public static func shouldApplyProgrammaticCaret(hasMarkedText: Bool) -> Bool {
        !hasMarkedText
    }

    public static func shouldCollapseCaretAfterProgrammaticFocus(query: String) -> Bool {
        !query.isEmpty && !selectsTypedQueryOnProgrammaticFocus()
    }

    /// Rewriting the SwiftUI field while the IME has marked text cancels
    /// composition, so the candidate window never stays open.
    public static func shouldSyncDisplayedSearchText(hasMarkedText: Bool) -> Bool {
        !hasMarkedText
    }

    /// SwiftUI `TextField` bindings rewrite marked text and garble CJK
    /// preedit. Search uses an AppKit field editor that only publishes
    /// committed strings.
    public static func usesAppKitFieldEditorForSearch() -> Bool {
        true
    }

    public static func shouldPublishFieldEditorString(
        hasMarkedText: Bool,
        isMarkedTextSession: Bool = false
    ) -> Bool {
        !hasMarkedText && !isMarkedTextSession
    }

    public static func shouldApplyExternalStringToFieldEditor(
        hasMarkedText: Bool,
        incoming: String,
        current: String,
        isEditing _: Bool = false,
        programmaticSync _: Bool = false
    ) -> Bool {
        !hasMarkedText && incoming != current
    }

    public static func shouldMakeSearchFieldFirstResponder(
        wantsFocus: Bool,
        isAlreadyEditing: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        wantsFocus && !isAlreadyEditing && !hasMarkedText
    }

    public static func notesSearchFieldUserEdit(
        isSearchMode: Bool,
        isDeleteKey: Bool,
        isCommandA: Bool
    ) -> Bool {
        isSearchMode && (isDeleteKey || isCommandA)
    }

    /// One apply plus one retry after the field editor mounts. A longer
    /// MainActor burst fights IME and walks the view tree on every turn.
    public static let caretCollapseApplyCount = 2

    public static func shouldRefreshCaretHost(
        queryChanged: Bool,
        collapseTokenChanged: Bool
    ) -> Bool {
        queryChanged || collapseTokenChanged
    }

    /// Leaving search (click away / picker mode) must drop the query so
    /// the next focus does not inherit the previous filter.
    public static func shouldClearQueryWhenLeavingSearch() -> Bool {
        true
    }
}

public struct MacClippyDockSearchFieldCaret: Equatable, Sendable {
    public var utf16Location: Int
    public var utf16Length: Int

    public init(utf16Location: Int, utf16Length: Int = 0) {
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
    }
}
