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

    func testTimestampCaptionLabelUsesLongRelativeCopy() {
        let now = Date()
        XCTAssertEqual(
            MacClippyDockTimestampPolicy.captionLabel(for: now.addingTimeInterval(-45), now: now),
            "1 minute ago"
        )
        XCTAssertEqual(
            MacClippyDockTimestampPolicy.captionLabel(for: now.addingTimeInterval(-120), now: now),
            "2 minutes ago"
        )
        XCTAssertEqual(
            MacClippyDockTimestampPolicy.captionLabel(for: now.addingTimeInterval(-3600), now: now),
            "1 hour ago"
        )
        XCTAssertEqual(
            MacClippyDockTimestampPolicy.captionLabel(for: now.addingTimeInterval(-13 * 3600), now: now),
            "13 hours ago"
        )
        XCTAssertEqual(
            MacClippyDockTimestampPolicy.captionLabel(for: now.addingTimeInterval(-90_000), now: now),
            "Yesterday"
        )
        XCTAssertNil(MacClippyDockTimestampPolicy.captionLabel(for: now.addingTimeInterval(60), now: now))
    }

    func testClipboardCarouselHeightIncludesBelowCardCaption() {
        let bodyAndPadding = MacClippyDockCardMetrics.height
            + MacClippyDockCardMetrics.carouselVerticalPadding * 2
        XCTAssertEqual(
            MacClippyDockCardMetrics.carouselHeight(for: .large),
            bodyAndPadding
                + MacClippyDockCardMetrics.captionSpacing
                + MacClippyDockCardMetrics.captionHeight
        )
    }

    func testClipboardCardSourceIsIconOnlyChrome() throws {
        let source = try appSource(named: "MacClippyClipboardCardLabel.swift")

        XCTAssertFalse(source.contains("clipboardCardHeader"))
        XCTAssertFalse(source.contains("cardCategoryFooter"))
        XCTAssertFalse(source.contains("Text(context.source.displayName)"))
        XCTAssertFalse(source.contains("MacClippyCardHeaderTrailingLabel"))
        XCTAssertTrue(source.contains("sourceCardBackground"))
        XCTAssertTrue(source.contains("context.source.accent"))
        XCTAssertFalse(source.contains("sourceBadgeFill"))
        XCTAssertTrue(source.contains("bottomTrailing"))
        XCTAssertTrue(source.contains(".help("))
        XCTAssertTrue(source.contains("accessibilityHidden"))
    }

    func testClipboardCardSourceIconSitsOutsideTheCardCorner() {
        XCTAssertEqual(MacClippyDockCardMetrics.sourceBadgeSize, 48)
        XCTAssertEqual(MacClippyDockCardMetrics.sourceBadgeOverlap, 20)
        XCTAssertEqual(MacClippyDockCardMetrics.gap, 32)
        XCTAssertEqual(MacClippyDockCardMetrics.padding, 24)
        XCTAssertEqual(MacClippyDockCardMetrics.imageInset, 16)
        XCTAssertEqual(MacClippyDockCardMetrics.imagePreviewRadius, 12)
        XCTAssertLessThan(MacClippyDockCardMetrics.imageInset, MacClippyDockCardMetrics.padding)
    }

    func testClipboardCardImagePreviewFitsInsideTheFace() throws {
        let label = try appSource(named: "MacClippyClipboardCardLabel.swift")
        XCTAssertTrue(label.contains("MacClippyDockCardMetrics.imageInset"))
        XCTAssertFalse(label.contains("fillsCard ? 0"))

        let image = try appSource(named: "MacClippyCardImageThumbnail.swift")
        XCTAssertTrue(image.contains("scaledToFit()"))
        XCTAssertFalse(image.contains("scaledToFill()"))

        let files = try appSource(named: "MacClippyFileThumbnailLoader.swift")
        XCTAssertTrue(files.contains("scaledToFit()"))
        XCTAssertFalse(files.contains("scaledToFill()"))
    }

    func testClipboardCardHoverDoesNotDrawASecondOffsetRing() throws {
        let hoverSource = try modifierSource()
        XCTAssertFalse(
            hoverSource.contains(".stroke("),
            "Hover must not paint a second ring. Badge padding centers that overlay off the card face."
        )
        XCTAssertTrue(hoverSource.contains("macClippyCardHovered"))
        XCTAssertTrue(hoverSource.contains("hoverAnimation"))
        XCTAssertFalse(hoverSource.contains("focusAnimation"))

        let cardSource = try appSource(named: "MacClippyClipboardCardLabel.swift")
        XCTAssertTrue(cardSource.contains("MacClippyCardBorderOverlay"))
        XCTAssertTrue(cardSource.contains("MacClippyDockCardHoverChrome"))
    }

    func testSourceCardBackgroundFillsTheRoundedFace() throws {
        let theme = try appSource(named: "MacClippyDockTheme.swift")
        guard let start = theme.range(of: "static func sourceCardBackground"),
              let end = theme.range(of: "static func snippetCardBackground") else {
            return XCTFail("sourceCardBackground is missing")
        }
        let body = String(theme[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(
            body.contains("shape.fill"),
            "A raw Color ZStack paints a square plate behind the rounded card."
        )
        XCTAssertFalse(body.contains("ZStack"))
    }

    func testClipboardCardButtonHasNoRectangularChrome() throws {
        let source = try appSource(named: "MacClippyDockCard.swift")
        XCTAssertTrue(source.contains("MacClippyCardButtonStyle"))
        XCTAssertFalse(
            source.contains(".buttonStyle(.plain)"),
            "Plain buttons still paint a rectangular backing on macOS."
        )
    }

    @MainActor
    func testClipboardCardBorderPolicyKeepsOneStroke() {
        XCTAssertEqual(
            MacClippyDockCardBorderPolicy.lineWidth(isActive: false, highContrast: false),
            1
        )
        XCTAssertEqual(
            MacClippyDockCardBorderPolicy.lineWidth(isActive: true, highContrast: false),
            2
        )
        XCTAssertFalse(MacClippyDockCardBorderPolicy.usesAccent(isActive: false, isHovered: false))
        XCTAssertTrue(MacClippyDockCardBorderPolicy.usesAccent(isActive: false, isHovered: true))
        XCTAssertTrue(MacClippyDockCardBorderPolicy.usesAccent(isActive: true, isHovered: false))
        XCTAssertEqual(MacClippyDockTheme.cardBorderInset, 0.5)
        XCTAssertEqual(MacClippyDockTheme.pillBorderInset, 0.5)
        XCTAssertEqual(MacClippyDockTheme.pillBorderWidth, 1)
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

    private func modifierSource() throws -> String {
        let source = try appSource(named: "MacClippyDockView.swift")
        guard let start = source.range(of: "struct MacClippyCardHoverModifier"),
              let end = source.range(of: "struct MacClippyDockView") else {
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
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
