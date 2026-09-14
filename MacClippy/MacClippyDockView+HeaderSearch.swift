import SwiftUI

import MacClippyCore
import MacClippyPlatform

struct MacClippyDockSearchFieldWell<Content: View>: View {
    let isSearchFocused: Bool
    let highContrast: Bool
    let reduceMotion: Bool
    let content: Content

    @State private var hoveredSearch = false

    init(
        isSearchFocused: Bool,
        highContrast: Bool,
        reduceMotion: Bool,
        @ViewBuilder content: () -> Content
    ) {
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
                    .inset(by: isSearchFocused ? 0 : MacClippyDockTheme.pillBorderInset)
                    .stroke(
                        searchStrokeColor,
                        lineWidth: searchStrokeWidth
                    )
            }
            .shadow(
                color: isSearchFocused && !highContrast
                    ? MacClippyDockTheme.searchFocusGlow
                    : .clear,
                radius: isSearchFocused ? 8 : 0
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
        if isSearchFocused {
            return MacClippyDockTheme.searchFocusRing
        }
        return MacClippyDockTheme.searchFieldEdge
    }

    private var searchStrokeWidth: CGFloat {
        if highContrast {
            return isSearchFocused ? 2 : 1
        }
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

    // Selection-mode header: count + Cancel on the left, primary/secondary
    // actions in the center, destructive actions on the right. Replaces the
    // old bottom action bar so the eye never leaves the card area.
    var selectionHeader: some View {
        GeometryReader { proxy in
            HStack(spacing: 8) {
                // Left: count badge (with number flip) + Cancel/Esc.
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("\(model.selectionCount)")
                            .id(model.selectionCount)
                            .transition(MacClippyMotion.numberFlipTransition(reduceMotion: reduceMotion))
                        Text("selected")
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(MacClippyDockTheme.textColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MacClippyDockTheme.accentSoftColor, in: Capsule())
                    .animation(MacClippyMotion.animation(MacClippyMotion.focusAnimation, reduceMotion: reduceMotion), value: model.selectionCount)

                    Button {
                        model.clearSelection()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.subheadline.weight(.bold))
                            Text("Cancel")
                                .font(.body.weight(.semibold))
                        }
                        .foregroundStyle(MacClippyDockTheme.textColor)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                    }
                    .macClippyChromeButtonStyle()
                    .help("Exit selection (Esc)")
                }

                Spacer(minLength: 8)

                // Center/right actions, horizontally scrollable on narrow widths.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        SelectionBarButton("Paste all", systemImage: "arrow.down.doc", emphasis: .primary) {
                            model.pasteSelectedAll(completion: { [weak model] in
                                _ = model
                                onClose()
                            })
                        }
                        .macClippyGlassEffectID("paste-all", in: headerGlassNamespace, enabled: !reduceMotion)
                        .staggeredAppearance(index: 0, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        SelectionBarButton("Queue paste", systemImage: "list.number") {
                            model.pasteQueued(completion: { [weak model] in
                                _ = model
                                onClose()
                            })
                        }
                        .staggeredAppearance(index: 1, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        SelectionBarButton("Copy all", systemImage: "doc.on.doc") {
                            model.copySelectedAll()
                        }
                        .staggeredAppearance(index: 2, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        if model.batchPinTarget != nil {
                            SelectionBarButton("Pin", systemImage: "pin") {
                                model.pinSelected()
                            }
                            .staggeredAppearance(index: 3, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        }
                        SelectionBarButton("Delete", systemImage: "trash", role: .destructive) {
                            model.deleteSelected()
                        }
                        .staggeredAppearance(index: 4, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        SelectionBarButton("Clear", systemImage: "xmark", role: .destructive) {
                            model.clearSelection()
                        }
                        .staggeredAppearance(index: 5, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: proxy.size.width * 0.62, alignment: .trailing)
            }
        }
        .onAppear { actionBarAppeared = true }
        .onDisappear { actionBarAppeared = false }
    }

    // Single horizontal top row: the search field takes about 42% of the
    // available row width, the category/tag pills share the same row to its
    // right. Cmd+K focuses the SwiftUI search field (wired in the dock
    // controller); the field no longer auto-focuses on dock show — the dock
    // is keyboard-first and the first card is focusable. Settings opens via
    // a direct gear button. GeometryReader sizes the search field to ~42% of
    // the row width (clamped so it stays usable on very narrow and very wide
    // screens) without animating width on screen changes.
    var topRow: some View {
        GeometryReader { proxy in
            let available = proxy.size.width
            let searchWidth = max(240, min(available * 0.42, 640))
            HStack(spacing: 0) {
                searchField
                    .frame(width: searchWidth, alignment: .leading)
                searchFilterChipRow
                    .padding(.leading, chipRowVisible ? 10 : 0)
                filterPillRow
                    .padding(.leading, 10)
            }
        }
        .onAppear {
            // Keyboard-first: do not steal focus into the search field on
            // launch. Reduce Motion is still reported to the controller.
            onReduceMotionChange(accessibilityReduceMotion)
        }
        .onChange(of: model.searchFocusRequest) { _, token in
            if MacClippyDockSearchQueryWritePolicy.shouldCollapseCaretAfterProgrammaticFocus(
                query: model.query
            ) {
                searchCaretCollapseToken = token
            }
            isSearchFocused = true
        }
        .onChange(of: model.searchFocusReset) { _, _ in isSearchFocused = false }
    }

    var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                // Plain magnifying-glass icon, no circular badge (reference).
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.medium))
                    .foregroundStyle(MacClippyDockTheme.muted2Color)
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
                        isSearchFocused = focused
                        onSearchModeChange(focused)
                    },
                    onCompositionChange: { composing in
                        onSearchCompositionChange(composing)
                    },
                    onSubmit: { model.reload() }
                )
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .help(
                        "Search clipboard history. Filter by source with app:Safari. Add clauses like "
                            + "type:text, type:url, name:work, has:name, has:ocr, before:YYYY-MM-DD, "
                            + "after:YYYY-MM-DD. Quote a phrase to keep it together. Bare words match any "
                            + "continuous fragment (ss finds passport)."
                    )
                searchClearButton
            }
            .macClippySearchFieldWell(
                isSearchFocused: isSearchFocused,
                highContrast: highContrast,
                reduceMotion: reduceMotion
            )
        }
    }

    private var mountedSearchFilterChips: [MacClippySearchFilterChip] {
        MacClippyDockSearchQueryWritePolicy.mountedSearchFilterChips(
            applied: model.searchFilterChips,
            suggestions: isSearchFocused ? model.searchFilterSuggestions : [],
            excludingTokens: MacClippySmartListPolicy.visibleListTokens(
                hiddenIDs: model.hiddenSmartListIDs
            )
        )
    }

    private var chipRowVisible: Bool {
        MacClippyDockSearchQueryWritePolicy.isChipRowVisible(
            isSearchFocused: isSearchFocused,
            hasAppliedChips: mountedSearchFilterChips.contains { !$0.isSuggestion }
        )
    }

    @ViewBuilder
    var searchFilterChipRow: some View {
        let chips = mountedSearchFilterChips
        if chipRowVisible, !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(chips) { chip in
                        searchFilterChip(chip)
                            .transition(MacClippyMotion.fadeTransition(reduceMotion: reduceMotion))
                    }
                }
            }
            .frame(maxWidth: MacClippyDockSearchQueryWritePolicy.chipRowMaxWidth(isVisible: true))
            .animation(
                MacClippyMotion.animation(MacClippyMotion.hoverAnimation, reduceMotion: reduceMotion),
                value: chips.map(\.id)
            )
            .accessibilityLabel("Search filters")
        }
    }

    @ViewBuilder
    var searchClearButton: some View {
        if MacClippyDockSearchQueryWritePolicy.isClearButtonVisible(hasQuery: !model.displayedSearchText.isEmpty) {
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

    func searchFilterChip(_ chip: MacClippySearchFilterChip) -> some View {
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
        isSearchFocused: Bool,
        highContrast: Bool,
        reduceMotion: Bool
    ) -> some View {
        MacClippyDockSearchFieldWell(
            isSearchFocused: isSearchFocused,
            highContrast: highContrast,
            reduceMotion: reduceMotion
        ) {
            self
        }
    }
}
