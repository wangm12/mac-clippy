import Foundation
import SwiftUI

import MacClippyCore

extension MacClippyDockView {
    @ViewBuilder
    func snippetCardContent(
        _ snippet: MacClippySnippetEntry,
        isFocused: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            snippetCardHeader(snippet)

            Rectangle()
                .fill(MacClippyDockTheme.lineColor)
                .frame(height: 1)

            highlightedText(
                snippet.preview.isEmpty ? "(empty)" : snippet.preview,
                font: MacClippyDockCardMetrics.contentFont,
                color: MacClippyDockTheme.textColor
            )
                .lineSpacing(1)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(MacClippyDockCardMetrics.padding)
        .frame(
            width: MacClippyDockCardMetrics.width,
            height: MacClippyDockCardMetrics.height(for: dynamicTypeSize),
            alignment: .topLeading
        )
        .contentShape(RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous))
        .background(MacClippyDockTheme.snippetCardBackground(elevated: isFocused))
        .overlay {
            MacClippyCardBorderOverlay(isActive: isFocused, highContrast: highContrast)
        }
        .modifier(MacClippySnippetHoverChrome(isFocused: isFocused))
    }

    @ViewBuilder
    private func snippetCardHeader(_ snippet: MacClippySnippetEntry) -> some View {
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
            }

            if let trigger = snippet.trigger, !trigger.isEmpty {
                Text(trigger)
                    .font(.callout.monospaced())
                    .foregroundStyle(MacClippyDockTheme.accentColor.opacity(0.9))
                    .lineLimit(1)
            }
        }
    }

    var emptyTitle: String {
        MacClippyDockEmptyStateCopy.title(
            query: model.query,
            tab: model.selectedTab,
            pinboardName: model.selectedPinboardName
        )
    }

    var emptySubtitle: String {
        MacClippyDockEmptyStateCopy.subtitle(query: model.query, tab: model.selectedTab)
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

private struct MacClippySnippetHoverChrome: ViewModifier {
    let isFocused: Bool
    @Environment(\.macClippyCardHovered) private var isHovered
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    func body(content: Content) -> some View {
        let reduceMotion = MacClippyMotion.shouldReduceMotion(swiftUI: accessibilityReduceMotion)
        content
            .shadow(
                color: .black.opacity(
                    MacClippyDockCardHoverChrome.shadowOpacity(
                        elevated: isFocused,
                        hovered: isHovered
                    )
                ),
                radius: MacClippyDockCardHoverChrome.shadowRadius(
                    elevated: isFocused,
                    hovered: isHovered
                ),
                y: MacClippyDockCardHoverChrome.shadowY(
                    elevated: isFocused,
                    hovered: isHovered
                )
            )
            .scaleEffect(reduceMotion ? 1 : (isHovered ? MacClippyMotion.hoverScale : 1))
    }
}
