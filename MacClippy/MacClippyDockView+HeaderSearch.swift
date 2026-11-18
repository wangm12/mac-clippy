import SwiftUI

import MacClippyCore
import MacClippyPlatform

struct MacClippyDockSearchFieldWell<Content: View>: View {
    let isSearchFocused: Bool
    let highContrast: Bool
    let reduceMotion: Bool
    let content: Content

    @State private var hoveredSearch = false

    init(isSearchFocused: Bool, highContrast: Bool, reduceMotion: Bool, @ViewBuilder content: () -> Content) {
        self.isSearchFocused = isSearchFocused
        self.highContrast = highContrast
        self.reduceMotion = reduceMotion
        self.content = content()
    }

    var body: some View {
        content
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 36)
            .macClippySearchFieldStyle(elevated: hoveredSearch || isSearchFocused)
            .overlay {
                Capsule()
                    .inset(by: MacClippyDockTheme.pillBorderInset)
                    .stroke(searchStrokeColor, lineWidth: searchStrokeWidth)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: isSearchFocused && !highContrast ? MacClippyDockTheme.searchFocusGlow : .clear,
                radius: 0
            )
            .onContinuousHover { phase in
                hoveredSearch = MacClippyDockHoverPolicy.isHovering(phase)
            }
            .animation(
                MacClippyMotion.animation(MacClippyMotion.hoverAnimation, reduceMotion: reduceMotion),
                value: hoveredSearch
            )
            .animation(
                MacClippyMotion.animation(MacClippyMotion.hoverAnimation, reduceMotion: reduceMotion),
                value: isSearchFocused
            )
    }

    private var searchStrokeColor: Color {
        if highContrast {
            return isSearchFocused ? MacClippyDockTheme.textColor : MacClippyDockTheme.lineColor
        }
        return isSearchFocused ? MacClippyDockTheme.searchFocusRing : MacClippyDockTheme.searchFieldEdge
    }

    private var searchStrokeWidth: CGFloat {
        if highContrast { return isSearchFocused ? 2 : 1 }
        return isSearchFocused ? MacClippyDockTheme.searchFocusRingWidth : 1
    }
}

extension MacClippyDockView {
    var header: some View {
        MacClippyGlassContainer(spacing: 6) {
            Group {
                if model.hasMultipleSelection {
                    selectionHeader
                        .transition(MacClippyMotion.headerTransition(reduceMotion: reduceMotion))
                } else {
                    topRow
                        .transition(MacClippyMotion.headerTransition(reduceMotion: reduceMotion))
                }
            }
        }
        .macClippyNavContainerShape()
    }

    func searchField(chipWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                // Plain magnifying-glass icon, no circular badge (reference).
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(
                        isSearchFocused
                            ? MacClippyDockTheme.accentColor
                            : MacClippyDockTheme.muted2Color
                    )
                searchFilterChipRow(maxWidth: chipWidth)
                nativeSearchField
                searchClearButton
            }
            .contentShape(Capsule())
            .onTapGesture {
                if !isSearchFocused {
                    isSearchFocused = true
                    onSearchModeChange(true)
                }
            }
            .macClippySearchFieldWell(
                isSearchFocused: isSearchFocused,
                highContrast: highContrast,
                reduceMotion: reduceMotion
            )
        }
    }

    private var nativeSearchField: some View {
    MacClippyAppKitSearchField(
        committedQuery: model.displayedSearchText,
        isFocused: isSearchFocused,
        collapseToken: searchCaretCollapseToken,
        programmaticSyncToken: searchFieldProgrammaticSyncToken
            + model.searchQueryProgrammaticWriteToken,
        onCommit: { incoming in
            model.commitSearchFieldText(incoming, hasMarkedText: false)
        },
        onFocusChange: { focused in
            // Native menus temporarily release the field editor. Search stays
            // the intended keyboard destination until an explicit result or
            // surface transition resets the model's focus request.
            guard focused || !model.searchFocusIsRequested else { return }
            guard isSearchFocused != focused else { return }
            isSearchFocused = focused
            onSearchModeChange(focused)
        },
        onCompositionChange: { composing in
            onSearchCompositionChange(composing)
        },
        onSubmit: { focusCard() }
    )
        .frame(minWidth: 200, maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .help(
            "Search clipboard history. Filter by source with app:Safari. Add clauses like "
                + "type:text, type:url, name:work, has:name, has:ocr, before:YYYY-MM-DD, "
                + "after:YYYY-MM-DD. Quote a phrase to keep it together. Bare words match any "
                + "continuous fragment (ss finds passport)."
        )
    }

    private var mountedSearchFilterChips: [MacClippySearchFilterChip] {
        MacClippyDockSearchQueryWritePolicy.mountedSearchFilterChips(
            applied: model.searchFilterChips,
            suggestions: []
        )
    }

    private var chipRowVisible: Bool {
        MacClippyDockSearchQueryWritePolicy.isChipRowVisible(
            isSearchFocused: isSearchFocused,
            hasAppliedChips: mountedSearchFilterChips.contains { !$0.isSuggestion }
        )
    }

    @ViewBuilder
    func searchFilterChipRow(maxWidth: CGFloat) -> some View {
        let chips = mountedSearchFilterChips
        if chipRowVisible, let chip = chips.first, maxWidth > 0 {
            Group {
                if chips.count == 1 {
                    searchFilterChip(chip, maximumTitleWidth: max(12, maxWidth - 28))
                } else {
                    Button {
                        model.isFilterPopoverPresented = true
                    } label: {
                        Text("\(chips.count) filters")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(MacClippyDockTheme.textColor)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .background(MacClippyDockTheme.accentSoftColor, in: Capsule())
                    .accessibilityLabel("Show all \(chips.count) search filters")
                    .help(chips.map(\.title).joined(separator: ", "))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .animation(
                MacClippyMotion.animation(MacClippyMotion.hoverAnimation, reduceMotion: reduceMotion),
                value: chips.map(\.id)
            )
        }
    }

    @ViewBuilder
    var searchClearButton: some View {
        if MacClippyDockSearchQueryWritePolicy.isClearButtonVisible(hasQuery: !model.query.isEmpty) {
            Button {
                model.clearSearchQuery()
                searchFieldProgrammaticSyncToken += 1
                isSearchFocused = true
                onSearchModeChange(true)
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MacClippyDockTheme.muted2Color)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear search")
            .help("Clear search")
        }
    }

    func searchFilterChip(
        _ chip: MacClippySearchFilterChip, maximumTitleWidth: CGFloat? = nil
    ) -> some View {
        Button {
            if chip.isSuggestion {
                model.appendSearchFilter(token: chip.token)
            } else {
                model.removeSearchFilter(token: chip.token)
            }
            searchFieldProgrammaticSyncToken += 1
            isSearchFocused = true
            onSearchModeChange(true)
        } label: {
            HStack(spacing: 4) {
                Text(chip.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maximumTitleWidth, alignment: .leading)
                if !chip.isSuggestion {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(
                chip.isSuggestion ? MacClippyDockTheme.muted2Color : MacClippyDockTheme.textColor
            )
            .padding(.horizontal, 8)
            .frame(height: 22)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(
            (chip.isSuggestion ? MacClippyDockTheme.lineColor : MacClippyDockTheme.accentSoftColor)
                .opacity(chip.isSuggestion ? 0.35 : 1),
            in: Capsule()
        )
        .accessibilityLabel(chip.isSuggestion ? "Add \(chip.title) filter" : "Remove \(chip.title) filter")
        .help(chip.isSuggestion ? "Add \(chip.token)" : "Remove \(chip.token)")
    }
}

private extension View {
    func macClippySearchFieldWell(
        isSearchFocused: Bool, highContrast: Bool, reduceMotion: Bool
    ) -> some View {
        MacClippyDockSearchFieldWell(
            isSearchFocused: isSearchFocused, highContrast: highContrast, reduceMotion: reduceMotion
        ) { self }
    }
}
