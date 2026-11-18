import AppKit
import SwiftUI
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyClipboardCardSnapshotTests: XCTestCase {
    @MainActor
    func testClipboardCardCaptionUsesLongRelativeTimestamp() throws {
        let now = Date()
        let item = try historyEntry(preview: "clip text", modified: now.addingTimeInterval(-120))
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

        XCTAssertEqual(MacClippyCardCaptionLabel.text(for: context, now: now), "2 minutes ago")
    }

    @MainActor
    func testClipboardCardAccessibilityKeepsSourceNameAndCategories() throws {
        let now = Date()
        let item = try historyEntry(preview: "clip text", modified: now.addingTimeInterval(-120))
        let context = MacClippyClipboardCardContext(
            item: item,
            index: 0,
            source: MacClippySourceAppPresentation(
                displayName: "Safari",
                icon: nil,
                accent: NSColor.systemBlue
            ),
            dedupRun: 3,
            isSelected: false,
            activeBorder: false,
            isElevated: false,
            categories: [
                MacClippyDockCategoryPresentation(id: .generate(), name: "Work", colorHex: "#3366FF")
            ],
            highlightTerms: [],
            isPreviewVisible: false,
            sourcePresentationGeneration: 0
        )

        let label = MacClippyDockCardAccessibilityPolicy.label(for: context, now: now)
        XCTAssertTrue(label.contains("from Safari"))
        XCTAssertTrue(label.contains("2 minutes ago"))
        XCTAssertTrue(label.contains("Categories: Work"))
        XCTAssertTrue(label.contains("3 copies"))
        XCTAssertFalse(label.contains("⌘1"))
    }

    @MainActor
    func testRemoteClipboardCardSnapshotAndAccessibility() throws {
        let remote = try historyEntry(preview: "from phone", isRemoteClipboard: true)
        let local = try historyEntry(preview: "from phone")
        let remoteContext = cardContext(item: remote, terms: [], selected: false, generation: 0)
        let localContext = cardContext(item: local, terms: [], selected: false, generation: 0)

        XCTAssertTrue(remoteContext.snapshot.isRemoteClipboard)
        XCTAssertFalse(localContext.snapshot.isRemoteClipboard)
        XCTAssertNotEqual(remoteContext, localContext)

        let label = MacClippyDockCardAccessibilityPolicy.label(for: remoteContext)
        XCTAssertTrue(label.contains(MacClippyDockCardRemoteClipboardPolicy.accessibilityPhrase))
        XCTAssertFalse(
            MacClippyDockCardAccessibilityPolicy.label(for: localContext)
                .contains(MacClippyDockCardRemoteClipboardPolicy.accessibilityPhrase)
        )

        let source = try appSource(named: "MacClippyClipboardCardLabel.swift")
        XCTAssertTrue(source.contains("cardBottomLeadingChrome"))
        XCTAssertTrue(source.contains("MacClippyDockCardRemoteClipboardPolicy.symbolName"))
        XCTAssertTrue(source.contains("alignment: .bottomLeading"))
    }

    @MainActor
    func testRemoteClipboardCardWritesPreviewImage() throws {
        let view = MacClippyClipboardCardPreviewFactory.card(isRemoteClipboard: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 320, height: 340)
        guard let nsImage = renderer.nsImage else {
            XCTFail("expected a rendered remote clipboard card")
            return
        }
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("expected PNG data for the remote clipboard card")
            return
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mac-clippy-remote-card-preview.png")
        try png.write(to: url)
        XCTAssertGreaterThan(png.count, 1_000)
        print("Wrote remote clipboard card preview to \(url.path)")
    }

    // Snippet cards are held to the same honesty rule as clipboard cards: no
    // ⌘1–9 chrome while nothing binds those chords to a card index.
    func testSnippetCardChromeOmitsUnwiredQuickPasteBadge() throws {
        let source = try appSource(named: "MacClippyDockCardContent.swift")

        XCTAssertFalse(source.contains("⌘"))
        XCTAssertFalse(source.contains("index + 1"))
    }

    @MainActor
    func testFileCardSnapshotIncludesPathNotJustFileName() throws {
        let url = URL(fileURLWithPath: "/Users/me/H1B/passport.pdf")
        let item = MacClippyHistoryEntry(
            meta: ClipboardItemMeta(
                id: .generate(),
                created: Date(timeIntervalSince1970: 1),
                modified: Date(timeIntervalSince1970: 1),
                deviceID: try XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                lamport: 1,
                preview: "passport.pdf"
            ),
            contentKind: .files,
            preview: "passport.pdf",
            fileURLs: [url]
        )
        let context = cardContext(item: item, terms: [], selected: false, generation: 0)

        XCTAssertEqual(context.snapshot.fileNames, ["passport.pdf"])
        XCTAssertEqual(context.snapshot.filePaths, ["/Users/me/H1B/passport.pdf"])
        XCTAssertEqual(context.snapshot.typeMetadataSubtitle, "1 file")
        XCTAssertEqual(MacClippyDockCardVisibleNamePolicy.text(for: item), "passport.pdf")
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

    func cardContext(
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

    func appSource(named fileName: String) throws -> String {
        try macClippyTestAppSource(named: fileName)
    }

    func modifierSource() throws -> String {
        let source = try appSource(named: "MacClippyDockView.swift")
        guard let start = source.range(of: "struct MacClippyCardHoverModifier"),
              let end = source.range(of: "struct MacClippyDockView") else {
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    func historyEntry(
        preview: String,
        customLabel: String? = nil,
        modified: Date = Date(timeIntervalSince1970: 1),
        isRemoteClipboard: Bool = false
    ) throws -> MacClippyHistoryEntry {
        MacClippyHistoryEntry(
            meta: ClipboardItemMeta(
                id: .generate(),
                created: modified,
                modified: modified,
                deviceID: try XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                lamport: 1,
                preview: preview,
                customLabel: customLabel
            ),
            contentKind: .text,
            preview: preview,
            isRemoteClipboard: isRemoteClipboard
        )
    }
}
