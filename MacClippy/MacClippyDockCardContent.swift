import AppKit
import Foundation
import SwiftUI

import MacClippyCore
import MacClippyPlatform

extension MacClippyDockView {
    @ViewBuilder
    func snippetCardContent(
        _ snippet: MacClippySnippetEntry,
        index: Int,
        isFocused: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            snippetCardHeader(snippet, index: index)

            Rectangle()
                .fill(MacClippyDockTheme.lineColor)
                .frame(height: 1)

            Text(snippet.preview.isEmpty ? "(empty)" : snippet.preview)
                .font(MacClippyDockCardMetrics.contentFont)
                .foregroundStyle(MacClippyDockTheme.textColor)
                .lineSpacing(1)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(MacClippyDockCardMetrics.padding)
        .frame(
            width: MacClippyDockCardMetrics.width,
            height: MacClippyDockCardMetrics.height,
            alignment: .topLeading
        )
        .contentShape(RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous))
        .background(MacClippyDockTheme.snippetCardBackground(elevated: isFocused))
        .overlay {
            RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous)
                .stroke(
                    isFocused
                        ? MacClippyDockTheme.accentColor.opacity(0.85)
                        : MacClippyDockTheme.lineColor,
                    lineWidth: highContrast ? (isFocused ? 2.5 : 1.5) : (isFocused ? 2 : 1)
                )
        }
        .shadow(color: .black.opacity(isFocused ? 0.10 : 0.06), radius: 14, y: 4)
    }

    @ViewBuilder
    private func snippetCardHeader(_ snippet: MacClippySnippetEntry, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Image(systemName: "text.quote")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(MacClippyDockTheme.accentColor)
                }
                .frame(width: 28, height: 28)
                .background(
                    MacClippyDockTheme.accentSoftColor,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(MacClippyDockTheme.accentColor.opacity(0.45), lineWidth: 1)
                )
                Text(snippet.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MacClippyDockTheme.textColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(MacClippyDockTheme.muted2Color)
                }
            }

            if let trigger = snippet.trigger, !trigger.isEmpty {
                Text(trigger)
                    .font(.callout.monospaced())
                    .foregroundStyle(MacClippyDockTheme.accentColor.opacity(0.9))
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    func clipboardCardLabel(context: MacClippyClipboardCardContext) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            clipboardCardHeader(context: context)

            cardContent(context.item)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if !context.categories.isEmpty {
                cardCategoryFooter(context.categories)
            }
        }
        .padding(MacClippyDockCardMetrics.padding)
        .frame(
            width: MacClippyDockCardMetrics.width,
            height: MacClippyDockCardMetrics.height,
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
            color: model.isPreviewVisible
                ? .clear
                : .black.opacity(context.isElevated ? 0.08 : 0.05),
            radius: model.isPreviewVisible ? 0 : 10,
            y: model.isPreviewVisible ? 0 : 3
        )
        .overlay(alignment: .topTrailing) {
            cardSelectionBadge(isSelected: context.isSelected)
        }
    }

    @ViewBuilder
    private func clipboardCardHeader(context: MacClippyClipboardCardContext) -> some View {
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
            if let timestamp = MacClippyDockTimestampPolicy.relativeLabel(for: context.item.meta.modified) {
                Text(timestamp)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(MacClippyDockTheme.muted3Color)
                    .lineLimit(1)
            } else if context.index < 9 {
                Text("⌘\(context.index + 1)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(MacClippyDockTheme.muted3Color)
            }
        }
        .frame(height: 36)
    }

    @ViewBuilder
    private func cardSelectionBadge(isSelected: Bool) -> some View {
        if isSelected {
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

    @ViewBuilder
    private func urlCardBody(_ url: URL, item: MacClippyHistoryEntry) -> some View {
        let originalURL = item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 6) {
            Text(originalURL.isEmpty ? url.absoluteString : originalURL)
                .font(MacClippyDockCardMetrics.contentMonospacedFont)
                .foregroundStyle(MacClippyDockTheme.contentTextColor)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func cardFilesBody(_ item: MacClippyHistoryEntry) -> some View {
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
                    Text(name.isEmpty ? "(file)" : name)
                        .font(MacClippyDockCardMetrics.contentFont)
                        .foregroundStyle(MacClippyDockTheme.contentTextColor)
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
    private func cardImageBody(_ item: MacClippyHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MacClippyCardImageThumbnail(item: item, model: model)
                .frame(maxWidth: .infinity, maxHeight: 96, alignment: .top)
            if let subtitle = item.typeMetadataSubtitle {
                Text(subtitle)
                    .font(MacClippyDockCardMetrics.contentFont)
                    .foregroundStyle(MacClippyDockTheme.mutedColor)
            }
            if let ocrPreview = item.preview.isEmpty ? nil : item.preview,
               !ocrPreview.isEmpty {
                Text(ocrPreview)
                    .font(MacClippyDockCardMetrics.contentFont)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(MacClippyDockTheme.mutedColor)
            }
            Spacer(minLength: 0)
        }
    }

    private func sourceIcon(
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

    @ViewBuilder
    private func cardContent(_ item: MacClippyHistoryEntry) -> some View {
        let classificationPreview = String(item.preview.prefix(2_000))
        let isText = item.contentKind == .text || item.contentKind == .html || item.contentKind == .rtf
        let isURL = MacClippyDockURLPolicy.url(from: classificationPreview) != nil
        let isCode = isText
            && !isURL
            && MacClippyDockCodePolicy.isCode(classificationPreview)

        VStack(alignment: .leading, spacing: 0) {
            Group {
                if item.contentKind == .files {
                    cardFilesBody(item)
                } else if item.contentKind == .image {
                    cardImageBody(item)
                } else if isURL, let url = MacClippyDockURLPolicy.url(from: classificationPreview) {
                    urlCardBody(url, item: item)
                } else if isCode {
                    codeCardBody(item)
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
    private func plainTextCardBody(_ item: MacClippyHistoryEntry) -> some View {
        let text = item.preview.isEmpty ? "(empty)" : String(item.preview.prefix(2_000))

        Text(text)
            .font(MacClippyDockCardMetrics.contentFont)
            .foregroundStyle(MacClippyDockTheme.contentTextColor)
            .lineSpacing(1)
            .lineLimit(8)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func codeCardBody(_ item: MacClippyHistoryEntry) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(String(item.preview.prefix(2_000)))
                .font(MacClippyDockCardMetrics.contentMonospacedFont)
                .foregroundStyle(MacClippyDockTheme.contentTextColor)
                .lineSpacing(1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollDisabled(true)
    }

    var emptyTitle: String {
        if case .pinboard = model.selectedTab {
            return model.selectedPinboardName.map { "\($0) is empty" } ?? "Pinboard is empty"
        }
        return model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "No clipboard history yet"
            : "No matches"
    }

    var emptySubtitle: String {
        if case .pinboard = model.selectedTab {
            return "Pinned items will appear here."
        }
        return model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Copied items will appear here."
            : "Try a different search."
    }

    private func iconName(for kind: ContentKind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .rtf: "textformat"
        case .image: "photo"
        case .files: "doc"
        }
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
