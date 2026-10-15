import AppKit
import SwiftUI
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

extension MacClippyClipboardCardSnapshotTests {
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

    func testClipboardCardSourceBadgeIsIconOnlyAndCaptionKeepsSource() throws {
        let source = try appSource(named: "MacClippyClipboardCardLabel.swift")

        XCTAssertFalse(source.contains("clipboardCardHeader"))
        XCTAssertFalse(source.contains("cardCategoryFooter"))
        XCTAssertTrue(source.contains("cardBottomLeadingChrome"))
        XCTAssertTrue(source.contains("bottomLeading"))
        XCTAssertTrue(source.contains("Text(context.source.displayName)"))
        XCTAssertTrue(source.contains("Text(\"· \" + time).fixedSize()"))
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
        XCTAssertTrue(label.contains("cardNamedPreview"))
        XCTAssertFalse(label.contains(".padding(fillsCard ? 0"))

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
    func testImageAndFileCardsAlwaysExposeAVisibleName() throws {
        let fileURL = URL(fileURLWithPath: "/Users/me/H1B/passport.jpg")
        let fileItem = MacClippyHistoryEntry(
            meta: ClipboardItemMeta(
                id: .generate(),
                created: Date(timeIntervalSince1970: 1),
                modified: Date(timeIntervalSince1970: 1),
                deviceID: try XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                lamport: 1,
                preview: "passport.jpg"
            ),
            contentKind: .files,
            preview: "passport.jpg",
            fileURLs: [fileURL]
        )
        let imageItem = try imageEntry()
        let namedImage = try imageEntry(customLabel: "Visa photo")

        XCTAssertEqual(MacClippyDockCardVisibleNamePolicy.text(for: fileItem), "passport.jpg")
        XCTAssertEqual(MacClippyDockCardVisibleNamePolicy.text(for: imageItem), "Image · 640×480")
        XCTAssertEqual(MacClippyDockCardVisibleNamePolicy.text(for: namedImage), "Visa photo")
        XCTAssertNil(MacClippyDockCardNameTagPolicy.text(for: namedImage))

        let namedText = try historyEntry(preview: "gsk_secret_token", customLabel: "Groq key")
        XCTAssertEqual(MacClippyDockCardNameTagPolicy.text(for: namedText), "Groq key")
        XCTAssertNil(MacClippyDockCardNameTagPolicy.text(for: try historyEntry(preview: "plain")))
        XCTAssertEqual(MacClippyDockCardNameTagPolicy.maximumLines, 2)

        let label = try appSource(named: "MacClippyClipboardCardLabel.swift")
        XCTAssertTrue(label.contains("MacClippyDockCardVisibleNamePolicy.text(for: item)"))
        XCTAssertTrue(label.contains("cardNamedPreview"))
        XCTAssertTrue(label.contains("cardImageBody"))
        XCTAssertTrue(label.contains("cardFilesBody"))
        XCTAssertTrue(label.contains("cardNameTag"))
        XCTAssertTrue(label.contains("MacClippyDockCardNameTagPolicy.text(for: item)"))
    }

    private func imageEntry(customLabel: String? = nil) throws -> MacClippyHistoryEntry {
        MacClippyHistoryEntry(
            meta: ClipboardItemMeta(
                id: .generate(), created: Date(timeIntervalSince1970: 1), modified: Date(timeIntervalSince1970: 1),
                deviceID: try XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                lamport: 1, preview: "(image 640x480)", customLabel: customLabel),
            contentKind: .image, preview: "(image 640x480)", imageDimensions: CGSize(width: 640, height: 480))
    }
}
