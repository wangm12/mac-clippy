import SwiftUI

import MacClippyCore

extension MacClippyClipboardCardLabel {
    @ViewBuilder
    func cardCategoryFooter(_ categories: [MacClippyDockCategoryPresentation]) -> some View {
        let visibleCategories = MacClippyDockCardCategoryPolicy.visibleCategories(from: categories)
        let overflowCount = MacClippyDockCardCategoryPolicy.overflowCount(for: categories)

        VStack(alignment: .leading, spacing: 7) {
            Rectangle()
                .fill(MacClippyDockTheme.lineColor)
                .frame(height: 1)

            HStack(spacing: 8) {
                ForEach(visibleCategories) { category in
                    cardCategoryTag(category)
                }
                if overflowCount > 0 {
                    cardCategoryOverflowTag(overflowCount)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cardCategoryTag(_ category: MacClippyDockCategoryPresentation) -> some View {
        let categoryColor = Color(macClippyHex: category.colorHex)
        return HStack(spacing: 5) {
            Circle()
                .fill(categoryColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(category.name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(MacClippyDockTheme.mutedColor)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(
            categoryColor.opacity(MacClippyDockTheme.isDark ? 0.16 : 0.10),
            in: Capsule()
        )
        .pillBorder(categoryColor.opacity(MacClippyDockTheme.isDark ? 0.34 : 0.24))
        .contentShape(Capsule())
        .layoutPriority(1)
    }

    private func cardCategoryOverflowTag(_ count: Int) -> some View {
        Text("+\(count)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(MacClippyDockTheme.muted2Color)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(MacClippyDockTheme.cardColor.opacity(0.52), in: Capsule())
            .pillBorder(MacClippyDockTheme.pillRestBorder)
            .contentShape(Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }
}
