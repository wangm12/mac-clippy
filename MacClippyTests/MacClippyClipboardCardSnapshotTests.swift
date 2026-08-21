import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyClipboardCardSnapshotTests: XCTestCase {
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
    func testClipboardCardHeaderOmitsQuickPasteBadge() throws {
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

        let trailingLabel = MacClippyCardHeaderTrailingLabel.text(for: context)
        XCTAssertNil(trailingLabel)
        XCTAssertFalse((trailingLabel ?? "").contains("⌘1"))
    }

    @MainActor
    func testClipboardCardHeaderTrailingLabelKeepsTimestamp() throws {
        let pastModified = Date().addingTimeInterval(-120)
        let item = try historyEntry(preview: "clip text", modified: pastModified)
        let context = MacClippyClipboardCardContext(
            item: item,
            index: 0,
            source: MacClippySourceAppPresentation(
                displayName: "Safari",
                icon: nil,
                accent: NSColor.systemBlue
            ),
            dedupRun: 1,
            isSelected: false,
            activeBorder: false,
            isElevated: false,
            categories: [],
            highlightTerms: [],
            isPreviewVisible: false,
            sourcePresentationGeneration: 0
        )

        XCTAssertEqual(MacClippyCardHeaderTrailingLabel.text(for: context), "2m")
    }

    // Snippet cards are held to the same honesty rule as clipboard cards: no
    // ⌘1–9 chrome while nothing binds those chords to a card index.
    func testSnippetCardChromeOmitsUnwiredQuickPasteBadge() throws {
        let source = try appSource(named: "MacClippyDockCardContent.swift")

        XCTAssertFalse(source.contains("⌘"))
        XCTAssertFalse(source.contains("index + 1"))
    }

    @MainActor
    func testThumbnailEqualityDependsOnlyOnItemID() throws {
        let first = try historyEntry(preview: "one")
        let second = try historyEntry(preview: "two")
        let left = MacClippyCardImageThumbnail(itemID: first.id, load: { _ in nil })
        let sameID = MacClippyCardImageThumbnail(itemID: first.id, load: { _ in
            XCTFail("loader closure must not participate in thumbnail equality")
            return nil
        })
        let other = MacClippyCardImageThumbnail(itemID: second.id, load: { _ in nil })

        XCTAssertEqual(left, sameID)
        XCTAssertNotEqual(left, other)
    }

    private func cardContext(
        item: MacClippyHistoryEntry,
        terms: [String],
        selected: Bool,
        generation: UInt
    ) -> MacClippyClipboardCardContext {
        MacClippyClipboardCardContext(
            item: item,
            index: 0,
            source: MacClippySourceAppPresentation(
                displayName: "Safari",
                icon: nil,
                accent: NSColor.systemBlue
            ),
            dedupRun: 2,
            isSelected: selected,
            activeBorder: true,
            isElevated: true,
            categories: [],
            highlightTerms: terms,
            isPreviewVisible: false,
            sourcePresentationGeneration: generation
        )
    }

    private func appSource(named fileName: String) throws -> String {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacClippy")
        return try String(contentsOf: sourceRoot.appendingPathComponent(fileName), encoding: .utf8)
    }

    private func historyEntry(
        preview: String,
        modified: Date = Date(timeIntervalSince1970: 1)
    ) throws -> MacClippyHistoryEntry {
        MacClippyHistoryEntry(
            meta: ClipboardItemMeta(
                id: .generate(),
                created: modified,
                modified: modified,
                deviceID: try XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                lamport: 1,
                preview: preview
            ),
            contentKind: .text,
            preview: preview
        )
    }
}
