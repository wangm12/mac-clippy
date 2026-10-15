import AppKit
import SwiftUI
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

extension MacClippyClipboardCardSnapshotTests {
    @MainActor
    func testContextEqualityIgnoresSourceIconAndTracksHighlightGeneration() throws {
        let item = try historyEntry(preview: "clip text")
        let redIcon = NSImage(size: NSSize(width: 8, height: 8))
        let blueIcon = NSImage(size: NSSize(width: 16, height: 16))
        let accent = NSColor.systemBlue
        let left = MacClippyClipboardCardContext(
            item: item,
            index: 0,
            source: MacClippySourceAppPresentation(
                displayName: "Safari",
                icon: redIcon,
                accent: accent
            ),
            dedupRun: 2,
            isSelected: false,
            activeBorder: true,
            isElevated: true,
            categories: [],
            highlightTerms: ["clip"],
            isPreviewVisible: false,
            sourcePresentationGeneration: 3
        )
        let right = MacClippyClipboardCardContext(
            item: item,
            index: 0,
            source: MacClippySourceAppPresentation(
                displayName: "Safari",
                icon: blueIcon,
                accent: NSColor.systemRed
            ),
            dedupRun: 2,
            isSelected: false,
            activeBorder: true,
            isElevated: true,
            categories: [],
            highlightTerms: ["clip"],
            isPreviewVisible: false,
            sourcePresentationGeneration: 3
        )

        XCTAssertEqual(left, right)
    }

    @MainActor
    func testContextInequalityTracksHighlightSelectionAndGeneration() throws {
        let item = try historyEntry(preview: "clip text")
        let left = cardContext(item: item, terms: ["clip"], selected: false, generation: 3)
        XCTAssertNotEqual(left, cardContext(item: item, terms: ["text"], selected: false, generation: 3))
        XCTAssertNotEqual(left, cardContext(item: item, terms: ["clip"], selected: false, generation: 4))
        XCTAssertNotEqual(left, cardContext(item: item, terms: ["clip"], selected: true, generation: 3))
    }

    @MainActor
    func testUnrelatedSourceResolveDoesNotInvalidateFileCardSnapshot() throws {
        let finderItem = try historyEntry(preview: "clip.mp4")
        var batch = MacClippySourceResolveBatch()
        let finderBefore = cardContext(
            item: finderItem,
            terms: [],
            selected: false,
            generation: MacClippySourceCardRefreshPolicy.snapshotGeneration(
                cardBundleID: "com.apple.finder",
                generations: batch.generations
            )
        )

        batch.enqueue("com.google.Chrome")
        batch.flush()
        let finderAfterChrome = cardContext(
            item: finderItem,
            terms: [],
            selected: false,
            generation: MacClippySourceCardRefreshPolicy.snapshotGeneration(
                cardBundleID: "com.apple.finder",
                generations: batch.generations
            )
        )
        XCTAssertEqual(finderBefore, finderAfterChrome)
        XCTAssertEqual(finderBefore.snapshot.sourcePresentationGeneration, 0)

        batch.enqueue("com.google.Chrome")
        batch.flush()
        let finderAfterChromeAgain = cardContext(
            item: finderItem,
            terms: [],
            selected: false,
            generation: MacClippySourceCardRefreshPolicy.snapshotGeneration(
                cardBundleID: "com.apple.finder",
                generations: batch.generations
            )
        )
        XCTAssertEqual(finderBefore, finderAfterChromeAgain)

        batch.enqueue("com.apple.finder")
        batch.flush()
        let finderAfterOwnResolve = cardContext(
            item: finderItem,
            terms: [],
            selected: false,
            generation: MacClippySourceCardRefreshPolicy.snapshotGeneration(
                cardBundleID: "com.apple.finder",
                generations: batch.generations
            )
        )
        XCTAssertNotEqual(finderBefore, finderAfterOwnResolve)
        XCTAssertEqual(finderAfterOwnResolve.snapshot.sourcePresentationGeneration, 1)
    }

    @MainActor
    func testClipboardCardCaptionOmitsQuickPasteBadge() throws {
        let futureModified = Date().addingTimeInterval(3600)
        let item = try historyEntry(preview: "clip text", modified: futureModified)
        let context = MacClippyClipboardCardContext(
            item: item,
            index: 0,
            source: MacClippySourceAppPresentation(
                displayName: "Safari",
                icon: nil,
                accent: NSColor.systemBlue
            ),
            dedupRun: 2,
            isSelected: false,
            activeBorder: true,
            isElevated: true,
            categories: [],
            highlightTerms: [],
            isPreviewVisible: false,
            sourcePresentationGeneration: 0
        )

        let caption = MacClippyCardCaptionLabel.text(for: context)
        XCTAssertNil(caption)
        XCTAssertFalse((caption ?? "").contains("⌘1"))
    }

}
