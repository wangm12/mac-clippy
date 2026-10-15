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
    let cachedThumbnail: @MainActor @Sendable (RecordID) -> CGImage?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.macClippyCardHovered) private var isHovered
    @Environment(\.macClippyCarouselScrolling) private var isCarouselScrolling

    init(
        context: MacClippyClipboardCardContext,
        loadThumbnail: @escaping @MainActor @Sendable (RecordID) async -> CGImage?,
        cachedThumbnail: @escaping @MainActor @Sendable (RecordID) -> CGImage? = { _ in nil }
    ) {
        snapshot = context.snapshot
        self.context = context
        self.loadThumbnail = loadThumbnail
        self.cachedThumbnail = cachedThumbnail
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    private var highContrast: Bool {
        colorSchemeContrast == .increased || differentiateWithoutColor
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

    var fillsCard: Bool {
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
            .padding(fillsCard ? MacClippyDockCardMetrics.imageInset : MacClippyDockCardMetrics.padding)
            .padding(.top, fillsCard ? 0 : 16)
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
                MacClippyCardBorderOverlay(
                    isActive: context.activeBorder,
                    highContrast: highContrast
                )
            }
            .scaleEffect(
                MacClippyDockCardHoverChrome.allowsHoverScale(
                    isScrolling: isCarouselScrolling,
                    reduceMotion: reduceMotion
                ) && isHovered ? MacClippyMotion.hoverScale : 1
            )
            .animation(
                MacClippyMotion.animation(MacClippyMotion.hoverAnimation, reduceMotion: reduceMotion),
                value: context.activeBorder
            )
            .animation(
                MacClippyMotion.animation(MacClippyMotion.actionFeedbackAnimation, reduceMotion: reduceMotion),
                value: context.isSelected
            )
            .overlay(alignment: .topTrailing) {
                cardSelectionBadge
            }
            .overlay(alignment: .bottomLeading) {
                cardBottomLeadingChrome
            }
    }

    private var cardCaption: some View {
        HStack(spacing: 4) {
            Text(context.source.displayName).lineLimit(1)
            if let time = MacClippyCardCaptionLabel.text(for: context) {
                Text("· " + time).fixedSize()
            }
        }
            .font(.caption)
            .foregroundStyle(MacClippyDockTheme.mutedColor)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: MacClippyDockCardMetrics.captionHeight)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var cardBottomLeadingChrome: some View {
        let categories = MacClippyDockCardCategoryPolicy.visibleCategories(from: context.categories)
        let overflow = MacClippyDockCardCategoryPolicy.overflowCount(for: context.categories)
        let showsCategories = context.showsCategoryIndicator && !categories.isEmpty
        let showsRemote = context.item.isRemoteClipboard
        if showsRemote || showsCategories {
            HStack(spacing: 6) {
                if showsRemote {
                    Image(systemName: MacClippyDockCardRemoteClipboardPolicy.symbolName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MacClippyDockTheme.contentTextColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(MacClippyDockTheme.cardColor, in: Capsule())
                        .help(MacClippyDockCardRemoteClipboardPolicy.help)
                }
                if showsCategories {
                    ForEach(categories) { category in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(macClippyHex: category.colorHex))
                                .frame(width: 7, height: 7)
                            Text(category.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(MacClippyDockTheme.contentTextColor)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(MacClippyDockTheme.cardColor, in: Capsule())
                    }
                    if overflow > 0 {
                        Text("+\(overflow)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MacClippyDockTheme.contentMutedColor)
                    }
                }
            }
            .padding(.leading, fillsCard ? MacClippyDockCardMetrics.imageInset : MacClippyDockCardMetrics.padding)
            .padding(.bottom, fillsCard ? MacClippyDockCardMetrics.imageInset : MacClippyDockCardMetrics.padding)
            .padding(.trailing, 56)
            .frame(maxWidth: MacClippyDockCardMetrics.width - 56, alignment: .leading)
            .accessibilityHidden(true)
        }
    }

    private var sourceAppBadge: some View {
        sourceBadgeIcon
            .environment(\.colorScheme, .light)
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
                sourceBadgeImage(icon)
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
    }

    @ViewBuilder
    private func sourceBadgeImage(_ icon: NSImage) -> some View {
        if let cgImage = MacClippySourceAppIcon.cgImage(icon) {
            Image(decorative: cgImage, scale: MacClippySourceAppIcon.rasterScale, orientation: .up)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        }
    }

    @ViewBuilder
    private var cardSelectionBadge: some View {
        if context.isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.callout.weight(.bold))
                .foregroundStyle(MacClippyDockTheme.accentColor)
                .background(Circle().fill(MacClippyDockTheme.cardColor))
                .frame(width: 22, height: 22)
                .offset(x: 3, y: -3)
                .transition(
                    reduceMotion
                        ? .identity
                        : .scale(scale: 0, anchor: .topTrailing).combined(with: .opacity)
                )
        }
    }
}
