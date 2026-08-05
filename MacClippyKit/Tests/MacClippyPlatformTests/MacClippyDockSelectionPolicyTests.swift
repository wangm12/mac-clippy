import AppKit
import Foundation
import XCTest

import MacClippyCore
import MacClippyPlatform

final class MacClippyDockSelectionPolicyTests: XCTestCase {
    private func ids(_ count: Int) -> [RecordID] {
        (0..<count).map { _ in RecordID.generate() }
    }

    // MARK: - Focus and single-select

    func testFocusingCollapsesSelectionToOneAndSetsAnchor() {
        let ordered = ids(5)
        let state = MacClippyDockSelectionState(
            orderedIDs: ordered,
            selectedIDs: Set(ordered),
            focusedIndex: 2,
            anchorIndex: 0
        )

        let next = MacClippyDockSelectionPolicy.focusing(state, at: 3)

        XCTAssertEqual(next.selectedIDs, [ordered[3]])
        XCTAssertEqual(next.focusedIndex, 3)
        XCTAssertEqual(next.anchorIndex, 3)
        XCTAssertEqual(next.orderedSelectedIDs, [ordered[3]])
        XCTAssertFalse(next.hasMultiple)
    }

    func testFocusingOutOfBoundsIndexDropsInvalidIDsAndKeepsFocus() {
        let ordered = ids(3)
        let stale = RecordID.generate()
        let state = MacClippyDockSelectionState(
            orderedIDs: ordered,
            selectedIDs: Set([stale] + ordered),
            focusedIndex: 10,
            anchorIndex: 10
        )

        // Focusing an out-of-bounds index is a defensive no-op on selection:
        // invalid IDs are cleaned (stale dropped), the valid selections stay,
        // and the (out-of-bounds) focus is left unchanged because we cannot
        // resolve a valid index to focus.
        let next = MacClippyDockSelectionPolicy.focusing(state, at: 99)

        XCTAssertEqual(next.selectedIDs, Set(ordered))
        XCTAssertEqual(next.focusedIndex, 10)
        XCTAssertEqual(next.orderedIDs, ordered)
    }

    // MARK: - Cmd-click toggle

    func testToggleAddsAndRemovesWithoutAffectingOthers() {
        let ordered = ids(4)
        let state = MacClippyDockSelectionState(orderedIDs: ordered, selectedIDs: [], focusedIndex: 0, anchorIndex: nil)

        let afterFirst = MacClippyDockSelectionPolicy.toggling(state, at: 1)
        XCTAssertEqual(afterFirst.selectedIDs, [ordered[1]])
        XCTAssertEqual(afterFirst.focusedIndex, 1)
        XCTAssertEqual(afterFirst.anchorIndex, 1)

        let afterSecond = MacClippyDockSelectionPolicy.toggling(afterFirst, at: 2)
        XCTAssertEqual(afterSecond.selectedIDs, [ordered[1], ordered[2]])
        XCTAssertTrue(afterSecond.hasMultiple)

        let afterThird = MacClippyDockSelectionPolicy.toggling(afterSecond, at: 1)
        XCTAssertEqual(afterThird.selectedIDs, [ordered[2]])
        XCTAssertEqual(afterThird.focusedIndex, 1)
        XCTAssertEqual(afterThird.anchorIndex, 1)
    }

    // MARK: - Shift-click range

    func testShiftClickExtendsRangeFromAnchor() {
        let ordered = ids(6)
        let state = MacClippyDockSelectionState(orderedIDs: ordered, selectedIDs: [ordered[1]], focusedIndex: 1, anchorIndex: 1)

        let forward = MacClippyDockSelectionPolicy.extendingRange(state, to: 4)
        XCTAssertEqual(forward.selectedIDs, Set(ordered[1...4]))
        XCTAssertEqual(forward.focusedIndex, 4)
        XCTAssertEqual(forward.anchorIndex, 1)

        let backward = MacClippyDockSelectionPolicy.extendingRange(forward, to: 0)
        XCTAssertEqual(backward.selectedIDs, Set(ordered[0...1]))
        XCTAssertEqual(backward.focusedIndex, 0)
        XCTAssertEqual(backward.anchorIndex, 1)
    }

    func testShiftClickWithNoAnchorFallsBackToFocusThenSelectsSpan() {
        let ordered = ids(5)
        let state = MacClippyDockSelectionState(orderedIDs: ordered, selectedIDs: [], focusedIndex: 2, anchorIndex: nil)

        let next = MacClippyDockSelectionPolicy.extendingRange(state, to: 4)
        XCTAssertEqual(next.selectedIDs, Set(ordered[2...4]))
        XCTAssertEqual(next.focusedIndex, 4)
        XCTAssertEqual(next.anchorIndex, 2)
    }

    // MARK: - Shift+arrow range extension

    func testShiftRightGrowsRangeFromAnchor() {
        let ordered = ids(5)
        let state = MacClippyDockSelectionState(orderedIDs: ordered, selectedIDs: [ordered[1]], focusedIndex: 1, anchorIndex: 1)

        let after = MacClippyDockSelectionPolicy.extendingRangeByStep(state, direction: .right)
        XCTAssertEqual(after.selectedIDs, Set(ordered[1...2]))
        XCTAssertEqual(after.focusedIndex, 2)
        XCTAssertEqual(after.anchorIndex, 1)
    }

    func testShiftLeftShrinksRangeBackTowardAnchor() {
        let ordered = ids(5)
        let state = MacClippyDockSelectionState(
            orderedIDs: ordered,
            selectedIDs: Set(ordered[1...3]),
            focusedIndex: 3,
            anchorIndex: 1
        )

        let after = MacClippyDockSelectionPolicy.extendingRangeByStep(state, direction: .left)
        XCTAssertEqual(after.selectedIDs, Set(ordered[1...2]))
        XCTAssertEqual(after.focusedIndex, 2)
        XCTAssertEqual(after.anchorIndex, 1)
    }

    func testShiftLeftPastAnchorFlipsAndGrowsRange() {
        let ordered = ids(5)
        let state = MacClippyDockSelectionState(
            orderedIDs: ordered,
            selectedIDs: Set(ordered[1...2]),
            focusedIndex: 2,
            anchorIndex: 1
        )

        // First Shift+Left shrinks back toward the anchor (focus 2 -> 1).
        let shrunk = MacClippyDockSelectionPolicy.extendingRangeByStep(state, direction: .left)
        XCTAssertEqual(shrunk.selectedIDs, [ordered[1]])
        XCTAssertEqual(shrunk.focusedIndex, 1)
        XCTAssertEqual(shrunk.anchorIndex, 1)

        // A second Shift+Left moves past the anchor (focus 1 -> 0) and now the
        // range flips and grows to cover [0...1].
        let flipped = MacClippyDockSelectionPolicy.extendingRangeByStep(shrunk, direction: .left)
        XCTAssertEqual(flipped.selectedIDs, Set(ordered[0...1]))
        XCTAssertEqual(flipped.focusedIndex, 0)
        XCTAssertEqual(flipped.anchorIndex, 1)
    }

    func testShiftArrowAtBoundariesClampsFocus() {
        let ordered = ids(3)
        let state = MacClippyDockSelectionState(orderedIDs: ordered, selectedIDs: [ordered[0]], focusedIndex: 0, anchorIndex: 0)

        let leftClamped = MacClippyDockSelectionPolicy.extendingRangeByStep(state, direction: .left)
        XCTAssertEqual(leftClamped.focusedIndex, 0)
        XCTAssertEqual(leftClamped.selectedIDs, [ordered[0]])

        let rightAtEdge = MacClippyDockSelectionState(orderedIDs: ordered, selectedIDs: [ordered[2]], focusedIndex: 2, anchorIndex: 2)
        let rightClamped = MacClippyDockSelectionPolicy.extendingRangeByStep(rightAtEdge, direction: .right)
        XCTAssertEqual(rightClamped.focusedIndex, 2)
        XCTAssertEqual(rightClamped.selectedIDs, [ordered[2]])
    }

    // MARK: - Plain arrow focus move

    func testPlainArrowCollapsesSelectionToNewFocus() {
        let ordered = ids(5)
        let state = MacClippyDockSelectionState(
            orderedIDs: ordered,
            selectedIDs: Set(ordered[1...3]),
            focusedIndex: 2,
            anchorIndex: 1
        )

        let right = MacClippyDockSelectionPolicy.movingFocus(state, direction: .right)
        XCTAssertEqual(right.selectedIDs, [ordered[3]])
        XCTAssertEqual(right.focusedIndex, 3)
        XCTAssertEqual(right.anchorIndex, 3)

        let left = MacClippyDockSelectionPolicy.movingFocus(state, direction: .left)
        XCTAssertEqual(left.selectedIDs, [ordered[1]])
        XCTAssertEqual(left.focusedIndex, 1)
        XCTAssertEqual(left.anchorIndex, 1)
    }

    // MARK: - Cmd+A select-all

    func testSelectAllSelectsEveryVisibleIDAndClearsAnchor() {
        let ordered = ids(4)
        let state = MacClippyDockSelectionState(orderedIDs: ordered, selectedIDs: [ordered[0]], focusedIndex: 1, anchorIndex: 1)

        let next = MacClippyDockSelectionPolicy.selectingAll(state)
        XCTAssertEqual(next.selectedIDs, Set(ordered))
        XCTAssertEqual(next.orderedSelectedIDs, ordered)
        XCTAssertTrue(next.hasMultiple)
        XCTAssertEqual(next.focusedIndex, 1)
        XCTAssertNil(next.anchorIndex)
    }

    func testSelectAllOnEmptyListIsNoOp() {
        let state = MacClippyDockSelectionState()
        let next = MacClippyDockSelectionPolicy.selectingAll(state)
        XCTAssertTrue(next.isEmpty)
    }

    // MARK: - Escape clear-selection-first

    func testClearSelectionKeepsFocusAndListButDropsSelectionAndAnchor() {
        let ordered = ids(4)
        let state = MacClippyDockSelectionState(
            orderedIDs: ordered,
            selectedIDs: Set(ordered),
            focusedIndex: 2,
            anchorIndex: 0
        )

        let next = MacClippyDockSelectionPolicy.clearingSelection(state)
        XCTAssertTrue(next.isEmpty)
        XCTAssertFalse(next.hasMultiple)
        XCTAssertEqual(next.focusedIndex, 2)
        XCTAssertEqual(next.orderedIDs, ordered)
        XCTAssertNil(next.anchorIndex)
    }

    // MARK: - Invalid/missing ID cleanup

    func testCleaningInvalidIDsDropsSelectionsNoLongerPresent() {
        let ordered = ids(3)
        let stale = RecordID.generate()
        let state = MacClippyDockSelectionState(
            orderedIDs: ordered,
            selectedIDs: [ordered[0], ordered[1], stale],
            focusedIndex: 0,
            anchorIndex: 0
        )

        let next = MacClippyDockSelectionPolicy.cleaningInvalidIDs(state)
        XCTAssertEqual(next.selectedIDs, [ordered[0], ordered[1]])
    }

    func testCleaningInvalidIDsIsNoOpWhenAllPresent() {
        let ordered = ids(3)
        let state = MacClippyDockSelectionState(
            orderedIDs: ordered,
            selectedIDs: [ordered[0], ordered[1]],
            focusedIndex: 0,
            anchorIndex: 0
        )

        let next = MacClippyDockSelectionPolicy.cleaningInvalidIDs(state)
        XCTAssertEqual(next, state)
    }

    // MARK: - Rebinding after reload / tab switch

    func testRebindingDropsStaleSelectionsAndClampsFocusAndAnchor() {
        let oldOrdered = ids(5)
        let state = MacClippyDockSelectionState(
            orderedIDs: oldOrdered,
            selectedIDs: Set(oldOrdered[0...3]),
            focusedIndex: 4,
            anchorIndex: 4
        )

        let newOrdered = Array(oldOrdered[0...2]) + [RecordID.generate()]
        let next = MacClippyDockSelectionPolicy.rebinding(state, to: newOrdered)

        XCTAssertEqual(next.orderedIDs, newOrdered)
        XCTAssertEqual(next.selectedIDs, Set(oldOrdered[0...2]))
        XCTAssertEqual(next.focusedIndex, 3)
        XCTAssertNil(next.anchorIndex)
    }

    // MARK: - Ordered selected IDs follow visual order

    func testOrderedSelectedIDsFollowVisualOrderNotSetIteration() {
        let ordered = ids(5)
        let state = MacClippyDockSelectionState(
            orderedIDs: ordered,
            selectedIDs: [ordered[4], ordered[0], ordered[2]],
            focusedIndex: 0,
            anchorIndex: nil
        )

        XCTAssertEqual(state.orderedSelectedIDs, [ordered[0], ordered[2], ordered[4]])
    }
}
