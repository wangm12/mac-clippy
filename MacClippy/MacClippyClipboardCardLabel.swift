import AppKit
import Foundation
import SwiftUI

import MacClippyCore

enum MacClippyCardHeaderTrailingLabel {
    static func text(for context: MacClippyClipboardCardContext, now: Date = Date()) -> String? {
        MacClippyDockTimestampPolicy.relativeLabel(
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
        VStack(alignment: .leading, spacing: 10) {
            clipboardCardHeader

            cardContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if !context.categories.isEmpty {
                cardCategoryFooter(context.categories)
            }
        }
        .padding(MacClippyDockCardMetrics.padding)
        .frame(
            width: MacClippyDockCardMetrics.width,
            height: MacClippyDockCardMetrics.height(for: dynamicTypeSize),
            alignment: .topLeading
        )
        .contentShape(RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous))
        .background(MacClippyDockTheme.sourceCardBackground(accent: context.source.accent))
        .overlay {
            RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous)
                .stroke(
                    context.activeBorder
                        ? MacClippyDockTheme.accentColor.opacity(0.85)
                        : MacClippyDockTheme.lineColor,
                    lineWidth: highContrast
                        ? (context.activeBorder ? 2.5 : 1.5)
                        : (context.activeBorder ? 1.5 : 1)
                )
        }
        .shadow(
            color: context.isPreviewVisible
                ? .clear
                : .black.opacity(context.isElevated ? 0.08 : 0.05),
            radius: context.isPreviewVisible ? 0 : 10,
            y: context.isPreviewVisible ? 0 : 3
        )
        .overlay(alignment: .topTrailing) {
            cardSelectionBadge
        }
    }

    private var clipboardCardHeader: some View {
        HStack(spacing: 9) {
            sourceIcon(context.source, size: 36)
            Text(context.item.customLabel ?? context.source.displayName)
                .font(.callout.weight(.semibold))
                .foregroundStyle(MacClippyDockTheme.textColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            if context.dedupRun > 1 {
                Text("×\(context.dedupRun)")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color(nsColor: context.source.accent))
            }
            if let trailingLabel = MacClippyCardHeaderTrailingLabel.text(for: context) {
                Text(trailingLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(MacClippyDockTheme.muted3Color)
                    .lineLimit(1)
            }
        }
        .frame(height: 36)
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

        VStack(alignment: .leading, spacing: 0) {
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
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
        let names = item.fileURLs.map(\.lastPathComponent)

        VStack(alignment: .leading, spacing: 2) {
            if names.isEmpty {
                Text(item.typeMetadataSubtitle ?? label(for: item.contentKind))
                    .font(MacClippyDockCardMetrics.contentFont)
                    .foregroundStyle(MacClippyDockTheme.contentTextColor)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            } else {
                ForEach(Array(names.prefix(3).enumerated()), id: \.offset) { _, name in
                    highlighted(
                        name.isEmpty ? "(file)" : name,
                        font: MacClippyDockCardMetrics.contentFont
                    )
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if names.count > 3 {
                    Text("+\(names.count - 3) more")
                        .font(MacClippyDockCardMetrics.contentFont)
                        .foregroundStyle(MacClippyDockTheme.contentMutedColor)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    func cardImageBody(_ item: MacClippyHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MacClippyCardImageThumbnail(itemID: item.id, load: loadThumbnail)
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: 96, alignment: .top)
            if let subtitle = item.typeMetadataSubtitle {
                Text(subtitle)
                    .font(MacClippyDockCardMetrics.contentFont)
                    .foregroundStyle(MacClippyDockTheme.mutedColor)
            }
            if let ocrPreview = item.preview.isEmpty ? nil : item.preview,
               !ocrPreview.isEmpty {
                highlighted(
                    ocrPreview,
                    font: MacClippyDockCardMetrics.contentFont,
                    color: MacClippyDockTheme.mutedColor
                )
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    func plainTextCardBody(_ item: MacClippyHistoryEntry) -> some View {
        let text = item.preview.isEmpty ? "(empty)" : String(item.preview.prefix(2_000))
            highlighted(
                text,
                font: MacClippyDockCardMetrics.contentFont
            )
            .lineSpacing(1)
            .lineLimit(8)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    func codeCardBody(_ item: MacClippyHistoryEntry, lineLimit: Int?) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            highlighted(
                String(item.preview.prefix(2_000)),
                font: MacClippyDockCardMetrics.contentMonospacedFont
            )
                .lineSpacing(1)
                .lineLimit(lineLimit)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollDisabled(true)
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

    func sourceIcon(
        _ source: MacClippySourceAppPresentation,
        size: CGFloat = 20
    ) -> some View {
        let corner: CGFloat = size > 20 ? 9 : 5
        return ZStack {
            if let icon = source.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(size > 20 ? .callout.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(Color(nsColor: source.accent))
            }
        }
        .frame(width: size, height: size)
        .background(
            Color(nsColor: source.accent).opacity(0.10),
            in: RoundedRectangle(cornerRadius: corner, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Color(nsColor: source.accent).opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
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
