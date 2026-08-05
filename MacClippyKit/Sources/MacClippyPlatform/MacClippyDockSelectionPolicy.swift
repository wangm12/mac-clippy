import Foundation

import MacClippyCore

// A pure, AppKit-independent multi-selection model for the clipboard dock.
//
// P1 adds Paste/Buffer-style multi-select on top of the existing single-focus
// dock without reintroducing a cluttered normal action row and without
// breaking single-click/double-click semantics. The selection is driven by a
// stable ordered list of RecordIDs (the dock's current visual order), a
// focused index (the keyboard cursor), and an anchor (the Shift-click/Shift-
// arrow range origin). Cmd-click toggles an individual ID, Shift-click and
// Shift+arrow extend the range from the anchor, Cmd+A selects every visible
// ID, and Escape clears the selection before the dock is dismissed.
//
// The model is intentionally a value type with no AppKit dependency so the
// selection logic can be unit-tested without Accessibility or UI automation.
// It is generic over the visible-item list supplied by the dock model: the
// policy never invents IDs, never reorders the supplied list, and never
// silently drops an ID — any ID that is no longer present in the visible list
// is dropped via a dedicated cleanup pass so the selection cannot reference a
// record that has been deleted or filtered out.
public struct MacClippyDockSelectionState: Equatable, Sendable {
    public let orderedIDs: [RecordID]
    public private(set) var selectedIDs: Set<RecordID>
    public private(set) var focusedIndex: Int
    public private(set) var anchorIndex: Int?

    public init(orderedIDs: [RecordID] = [], selectedIDs: Set<RecordID> = [], focusedIndex: Int = 0, anchorIndex: Int? = nil) {
        self.orderedIDs = orderedIDs
        self.selectedIDs = selectedIDs
        self.focusedIndex = focusedIndex
        self.anchorIndex = anchorIndex
    }

    public var count: Int { selectedIDs.count }
    public var isEmpty: Bool { selectedIDs.isEmpty }
    public var hasMultiple: Bool { selectedIDs.count > 1 }

    public var focusedID: RecordID? {
        guard orderedIDs.indices.contains(focusedIndex) else { return nil }
        return orderedIDs[focusedIndex]
    }

    public func contains(_ id: RecordID) -> Bool { selectedIDs.contains(id) }

    public func isSelected(at index: Int) -> Bool {
        guard orderedIDs.indices.contains(index) else { return false }
        return selectedIDs.contains(orderedIDs[index])
    }

    // Selections in the dock's current visual order, with invalid/missing IDs
    // removed. Used by ordered multi-paste so the merged payload follows what
    // the user sees, not an arbitrary Set iteration order.
    public var orderedSelectedIDs: [RecordID] {
        orderedIDs.filter { selectedIDs.contains($0) }
    }
}

public enum MacClippyDockSelectionPolicy {
    // Rebind the policy to a new visible-item list (e.g. after a reload or a
    // tab switch). The focused index is clamped into the new list, and any
    // selected ID that is no longer present is dropped via cleanup. The anchor
    // is dropped if its index is out of bounds; it is NOT remapped by ID
    // because the anchor is an index-based range origin and reusing a stale
    // index would silently extend the wrong range.
    public static func rebinding(
        _ state: MacClippyDockSelectionState,
        to orderedIDs: [RecordID]
    ) -> MacClippyDockSelectionState {
        let valid = Set(orderedIDs)
        let cleanedSelected = state.selectedIDs.intersection(valid)
        let clampedFocus = clampFocusedIndex(state.focusedIndex, count: orderedIDs.count)
        let clampedAnchor: Int? = {
            guard let anchor = state.anchorIndex, orderedIDs.indices.contains(anchor) else { return nil }
            return anchor
        }()
        return MacClippyDockSelectionState(
            orderedIDs: orderedIDs,
            selectedIDs: cleanedSelected,
            focusedIndex: clampedFocus,
            anchorIndex: clampedAnchor
        )
    }

    // Focus a single index and collapse the selection to just that ID. This is
    // the plain single-click / plain-arrow semantic: one focused card, one
    // selected card, panel stays open.
    public static func focusing(
        _ state: MacClippyDockSelectionState,
        at index: Int
    ) -> MacClippyDockSelectionState {
        guard state.orderedIDs.indices.contains(index) else {
            return cleaningInvalidIDs(state)
        }
        return MacClippyDockSelectionState(
            orderedIDs: state.orderedIDs,
            selectedIDs: [state.orderedIDs[index]],
            focusedIndex: index,
            anchorIndex: index
        )
    }

    // Cmd-click toggle: flip the membership of the clicked ID, move focus to
    // it, and set the anchor to it so a subsequent Shift-click/Shift+arrow
    // extends from the last toggled card. Toggling the focused card off is
    // allowed; focus still follows the click so the keyboard cursor is
    // unambiguous.
    public static func toggling(
        _ state: MacClippyDockSelectionState,
        at index: Int
    ) -> MacClippyDockSelectionState {
        guard state.orderedIDs.indices.contains(index) else {
            return cleaningInvalidIDs(state)
        }
        let id = state.orderedIDs[index]
        var selected = state.selectedIDs
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        return MacClippyDockSelectionState(
            orderedIDs: state.orderedIDs,
            selectedIDs: selected,
            focusedIndex: index,
            anchorIndex: index
        )
    }

    // Shift-click range: select every ID from the anchor (or the current focus
    // when no anchor exists) through the clicked index, inclusive. Focus moves
    // to the clicked index; the anchor is preserved so a later Shift-click in
    // the other direction re-extends from the same origin. A Shift-click with
    // no existing selection falls back to a plain focus at the clicked index.
    public static func extendingRange(
        _ state: MacClippyDockSelectionState,
        to index: Int
    ) -> MacClippyDockSelectionState {
        guard state.orderedIDs.indices.contains(index) else {
            return cleaningInvalidIDs(state)
        }
        let origin = state.anchorIndex ?? state.focusedIndex
        guard state.orderedIDs.indices.contains(origin) else {
            return focusing(state, at: index)
        }
        let lower = min(origin, index)
        let upper = max(origin, index)
        let range = Set(state.orderedIDs[lower...upper])
        return MacClippyDockSelectionState(
            orderedIDs: state.orderedIDs,
            selectedIDs: range,
            focusedIndex: index,
            anchorIndex: origin
        )
    }

    // Shift+arrow range extension: move focus one step in the given direction
    // and grow (or shrink) the range from the anchor to the new focus. Moving
    // back toward the anchor shrinks the range; moving away grows it. With no
    // existing selection this behaves like a plain focus+step and then selects
    // the span from the old focus to the new focus, which matches the common
    // Shift+arrow contract.
    public static func extendingRangeByStep(
        _ state: MacClippyDockSelectionState,
        direction: MacClippyDockSelectionDirection
    ) -> MacClippyDockSelectionState {
        guard !state.orderedIDs.isEmpty else { return state }
        let newIndex = clampedFocus(afterStepping: state.focusedIndex, direction: direction, count: state.orderedIDs.count)
        let origin = state.anchorIndex ?? state.focusedIndex
        guard state.orderedIDs.indices.contains(origin) else {
            return focusing(state, at: newIndex)
        }
        let lower = min(origin, newIndex)
        let upper = max(origin, newIndex)
        let range = Set(state.orderedIDs[lower...upper])
        return MacClippyDockSelectionState(
            orderedIDs: state.orderedIDs,
            selectedIDs: range,
            focusedIndex: newIndex,
            anchorIndex: origin
        )
    }

    // Plain arrow focus move (no Shift): move focus one step and collapse the
    // selection to the new focused ID. The anchor follows focus so a later
    // Shift+arrow extends from the new position.
    public static func movingFocus(
        _ state: MacClippyDockSelectionState,
        direction: MacClippyDockSelectionDirection
    ) -> MacClippyDockSelectionState {
        guard !state.orderedIDs.isEmpty else { return state }
        let newIndex = clampedFocus(afterStepping: state.focusedIndex, direction: direction, count: state.orderedIDs.count)
        return focusing(state, at: newIndex)
    }

    // Cmd+A: select every visible ID. Focus stays at its current clamped
    // position; the anchor is cleared so a subsequent Shift+arrow extends from
    // the focused card rather than from an arbitrary prior anchor.
    public static func selectingAll(_ state: MacClippyDockSelectionState) -> MacClippyDockSelectionState {
        guard !state.orderedIDs.isEmpty else { return state }
        return MacClippyDockSelectionState(
            orderedIDs: state.orderedIDs,
            selectedIDs: Set(state.orderedIDs),
            focusedIndex: clampFocusedIndex(state.focusedIndex, count: state.orderedIDs.count),
            anchorIndex: nil
        )
    }

    // Escape: clear the selection but keep the focus and the visible list. The
    // dock controller calls this first; a second Escape then dismisses the
    // dock. Keeping focus means the keyboard cursor is unchanged after the
    // selection is cleared.
    public static func clearingSelection(_ state: MacClippyDockSelectionState) -> MacClippyDockSelectionState {
        MacClippyDockSelectionState(
            orderedIDs: state.orderedIDs,
            selectedIDs: [],
            focusedIndex: clampFocusedIndex(state.focusedIndex, count: state.orderedIDs.count),
            anchorIndex: nil
        )
    }

    // Drop any selected ID that is no longer present in the visible ordered
    // list. This runs after a reload or a tab switch so the selection never
    // references a deleted or filtered-out record. Focus and anchor are
    // clamped by the caller (rebinding) after this pass.
    public static func cleaningInvalidIDs(_ state: MacClippyDockSelectionState) -> MacClippyDockSelectionState {
        let valid = Set(state.orderedIDs)
        let cleaned = state.selectedIDs.intersection(valid)
        guard cleaned.count != state.selectedIDs.count else { return state }
        return MacClippyDockSelectionState(
            orderedIDs: state.orderedIDs,
            selectedIDs: cleaned,
            focusedIndex: state.focusedIndex,
            anchorIndex: state.anchorIndex
        )
    }

    private static func clampFocusedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    private static func clampedFocus(
        afterStepping focus: Int,
        direction: MacClippyDockSelectionDirection,
        count: Int
    ) -> Int {
        guard count > 0 else { return 0 }
        switch direction {
        case .left:
            return max(focus - 1, 0)
        case .right:
            return min(focus + 1, count - 1)
        }
    }
}

public enum MacClippyDockSelectionDirection: Equatable, Sendable {
    case left
    case right
}
