import AppKit
import Foundation
import SwiftUI

import MacClippyCore

enum MacClippyCardCaptionLabel {
    static func text(for context: MacClippyClipboardCardContext, now: Date = Date()) -> String? {
        MacClippyDockTimestampPolicy.captionLabel(
            for: context.item.meta.modified,
            now: now
        )
    }
}

struct MacClippyClipboardCardLabel: View, Equatable {
    nonisolated let snapshot: MacClippyClipboardCardSnapshot
    let context: MacClippyClipboardCardContext
    let loadThumbnail: @MainActor @Sendable (RecordID) async -> CGImage?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    init(
        context: MacClippyClipboardCardContext,
        loadThumbnail: @escaping @MainActor @Sendable (RecordID) async -> CGImage?
    ) {
        snapshot = context.snapshot
        self.context = context
        self.loadThumbnail = loadThumbnail
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    private var highContrast: Bool {
        colorSchemeContrast == .increased
            || differentiateWithoutColor
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            || NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
    }

    private var reduceMotion: Bool {
        MacClippyMotion.shouldReduceMotion(swiftUI: accessibilityReduceMotion)
    }

    var body: some View {
        VStack(spacing: MacClippyDockCardMetrics.captionSpacing) {
            cardFace
                .overlay(alignment: .bottomTrailing) {
                    sourceAppBadge
                }
            cardCaption
        }
        .frame(width: MacClippyDockCardMetrics.width)
        .padding(.trailing, MacClippyDockCardMetrics.sourceBadgeOverlap)
    }

    private var fillsCard: Bool {
        switch context.item.contentKind {
        case .image:
            return true
        case .files:
            guard let url = context.item.fileURLs.first else { return false }
            return MacClippyFilePresentation.mediaKind(for: url) == .image
        case .text, .html, .rtf:
            return false
        }
    }

    private var cardFace: some View {
        let shape = RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous)
        return cardContent
            .padding(fillsCard ? 0 : MacClippyDockCardMetrics.padding)
            .frame(
                width: MacClippyDockCardMetrics.width,
                height: MacClippyDockCardMetrics.height(for: dynamicTypeSize),
                alignment: fillsCard ? .center : .topLeading
            )
            .contentShape(shape)
            .background(
                MacClippyDockTheme.sourceCardBackground(
                    accent: context.source.accent,
                    elevated: context.isElevated
                )
            )
            .clipShape(shape)
            .overlay {
                shape.stroke(
                    context.activeBorder
                        ? MacClippyDockTheme.accentColor.opacity(0.9)
                        : MacClippyDockTheme.lineColor,
                    lineWidth: highContrast
                        ? (context.activeBorder ? 2.5 : 1.5)
                        : (context.activeBorder ? 2 : 1)
                )
            }
            .shadow(
                color: context.isPreviewVisible
                    ? .clear
                    : .black.opacity(context.isElevated ? 0.16 : 0.08),
                radius: context.isPreviewVisible ? 0 : 12,
                y: context.isPreviewVisible ? 0 : 4
            )
            .overlay(alignment: .topTrailing) {
                cardSelectionBadge
            }
    }

    private var cardCaption: some View {
        Text(MacClippyCardCaptionLabel.text(for: context) ?? " ")
            .font(.caption.weight(.medium))
            .foregroundStyle(MacClippyDockTheme.muted2Color)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: MacClippyDockCardMetrics.captionHeight)
            .opacity(MacClippyCardCaptionLabel.text(for: context) == nil ? 0 : 1)
            .accessibilityHidden(true)
    }

    private var sourceAppBadge: some View {
        sourceBadgeIcon
            .help(context.source.displayName)
            .accessibilityHidden(true)
            .offset(
                x: MacClippyDockCardMetrics.sourceBadgeOverlap,
                y: MacClippyDockCardMetrics.sourceBadgeOverlap
            )
    }

    private var sourceBadgeIcon: some View {
        Group {
            if let icon = context.source.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color(nsColor: context.source.accent))
            }
        }
        .frame(
            width: MacClippyDockCardMetrics.sourceBadgeSize,
            height: MacClippyDockCardMetrics.sourceBadgeSize
        )
        .shadow(color: .black.opacity(0.32), radius: 3, y: 1)
    }

    @ViewBuilder
    private var cardSelectionBadge: some View {
        if context.isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.callout.weight(.bold))
                .foregroundStyle(MacClippyDockTheme.accentColor)
                .background(Circle().fill(MacClippyDockTheme.cardColor))
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .offset(x: 3, y: -3)
                .transition(
                    reduceMotion
                        ? .identity
                        : .scale(scale: 0, anchor: .topTrailing).combined(with: .opacity)
                )
        }
    }
}

extension MacClippyClipboardCardLabel {
    @ViewBuilder
    var cardContent: some View {
        let item = context.item
        let classificationPreview = String(item.preview.prefix(2_000))
        let isText = item.contentKind == .text || item.contentKind == .html || item.contentKind == .rtf
        let presentationKind = isText
            ? MacClippyClipboardPresentation.kind(forPlainText: classificationPreview)
            : .plain

        Group {
            if item.contentKind == .files {
                cardFilesBody(item)
            } else if item.contentKind == .image {
                cardImageBody(item)
            } else if case let .color(swatch) = presentationKind {
                colorCardBody(swatch)
            } else if presentationKind == .url,
                      let url = MacClippyClipboardPresentation.url(fromPlainText: classificationPreview) {
                urlCardBody(url, item: item)
            } else if presentationKind == .json {
                codeCardBody(item, lineLimit: 1)
            } else if presentationKind == .code {
                codeCardBody(item, lineLimit: nil)
            } else {
                plainTextCardBody(item)
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: fillsCard ? .center : .topLeading
        )
    }

    @ViewBuilder
    func urlCardBody(_ url: URL, item: MacClippyHistoryEntry) -> some View {
        let originalURL = item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 6) {
            highlighted(
                originalURL.isEmpty ? url.absoluteString : originalURL,
                font: MacClippyDockCardMetrics.contentMonospacedFont
            )
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    func colorCardBody(_ swatch: MacClippyColorSwatch) -> some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    Color(
                        red: Double(swatch.rgb.red) / 255,
                        green: Double(swatch.rgb.green) / 255,
                        blue: Double(swatch.rgb.blue) / 255
                    )
                )
                .frame(width: 28, height: 28)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(MacClippyDockTheme.lineColor, lineWidth: 1)
                }
            highlighted(
                swatch.hex,
                font: MacClippyDockCardMetrics.contentMonospacedFont
            )
            .lineLimit(1)
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .accessibilityLabel("Color \(swatch.hex)")
    }

    @ViewBuilder
    func cardFilesBody(_ item: MacClippyHistoryEntry) -> some View {
        let urls = item.fileURLs
        let pointSize = CGSize(
            width: MacClippyDockCardMetrics.width,
            height: MacClippyDockCardMetrics.height
        )
        if let url = urls.first, MacClippyFilePresentation.mediaKind(for: url) == .image {
            MacClippyFileThumbnail(url: url, pointSize: pointSize)
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let url = urls.first {
            VStack(spacing: 10) {
                MacClippyFileThumbnail(url: url, pointSize: CGSize(width: 96, height: 96))
                    .equatable()
                    .frame(width: 72, height: 72)
                highlighted(
                    MacClippyFilePresentation.displayName(for: url),
                    font: .callout.weight(.medium)
                )
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(item.typeMetadataSubtitle ?? label(for: item.contentKind))
                .font(MacClippyDockCardMetrics.contentFont)
                .foregroundStyle(MacClippyDockTheme.contentMutedColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    func cardImageBody(_ item: MacClippyHistoryEntry) -> some View {
        MacClippyCardImageThumbnail(itemID: item.id, load: loadThumbnail)
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    func plainTextCardBody(_ item: MacClippyHistoryEntry) -> some View {
        let text = item.preview.isEmpty ? "(empty)" : String(item.preview.prefix(2_000))
            highlighted(
                text,
                font: MacClippyDockCardMetrics.contentFont
            )
            .lineSpacing(4)
            .lineLimit(9)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    func codeCardBody(_ item: MacClippyHistoryEntry, lineLimit: Int?) -> some View {
        highlighted(
            String(item.preview.prefix(2_000)),
            font: MacClippyDockCardMetrics.contentMonospacedFont
        )
        .lineSpacing(3)
        .lineLimit(lineLimit ?? 11)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func highlighted(
        _ text: String,
        font: Font,
        color: Color = MacClippyDockTheme.contentTextColor
    ) -> Text {
        MacClippyDockCardHighlight.text(
            text,
            font: font,
            color: color,
            terms: context.highlightTerms
        )
    }

    func label(for kind: ContentKind) -> String {
        switch kind {
        case .text: "Text"
        case .html: "HTML"
        case .rtf: "Rich text"
        case .image: "Image"
        case .files: "Files"
        }
    }
}
