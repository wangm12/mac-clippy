import AppKit
import MacClippyCore
import SwiftUI

enum MacClippyDockHeaderLayoutPolicy {
    static let controlWidth: CGFloat = 36
    static let groupSpacing: CGFloat = 12
    static let controlSpacing: CGFloat = 8

    static let captureStatusWidth: CGFloat = 72

    private static func trailingControlsWidth(captureStatusWidth: CGFloat) -> CGFloat {
        controlWidth * 3 + controlSpacing * 2
            + (captureStatusWidth > 0 ? captureStatusWidth + controlSpacing : 0)
    }

    static func searchWidth(available: CGFloat, captureStatusWidth: CGFloat = 0) -> CGFloat {
        let preferred = min(448, max(384, (available * 0.3 / 4).rounded(.down) * 4))
        let side = max(220, trailingControlsWidth(captureStatusWidth: captureStatusWidth))
        let affordable = max(280, available - (side + groupSpacing) * 2)
        return min(preferred, affordable)
    }

    static func navigationWidth(available: CGFloat, captureStatusWidth: CGFloat = 0) -> CGFloat {
        max(0, (available - searchWidth(available: available, captureStatusWidth: captureStatusWidth)) / 2
            - groupSpacing)
    }

    static func chipWidth(searchWidth: CGFloat) -> CGFloat {
        let available = min(144, searchWidth - 304)
        return available >= 48 ? available : 0
    }
}

extension MacClippyDockView {
    var topRow: some View {
        GeometryReader { proxy in
            let statusWidth = captureStatusText == nil ? 0 : MacClippyDockHeaderLayoutPolicy.captureStatusWidth
            let width = MacClippyDockHeaderLayoutPolicy.navigationWidth(
                available: proxy.size.width, captureStatusWidth: statusWidth)
            let searchWidth = MacClippyDockHeaderLayoutPolicy.searchWidth(
                available: proxy.size.width, captureStatusWidth: statusWidth)
            HStack(spacing: 0) {
                rangeNavigation(width: width).frame(width: width, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: MacClippyDockHeaderLayoutPolicy.controlSpacing) {
                    if let captureStatusText {
                        Text(captureStatusText)
                            .font(.caption)
                            .foregroundStyle(MacClippyDockTheme.muted2Color)
                            .lineLimit(1)
                            .frame(width: statusWidth, alignment: .trailing)
                            .help("Open More actions to resume capture or cancel ignoring copies")
                    }
                    filtersButton
                    utilitiesMenu
                    settingsButton
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay {
                searchField(chipWidth: MacClippyDockHeaderLayoutPolicy.chipWidth(searchWidth: searchWidth))
                    .frame(width: searchWidth)
            }
        }
        .onChange(of: model.searchFocusRequest) { _, _ in
            guard model.searchFocusIsRequested else { return }
            if !model.query.isEmpty { searchCaretCollapseToken += 1 }
            isSearchFocused = true
        }
        .onChange(of: model.searchFocusReset) { _, _ in
            guard !model.searchFocusIsRequested else { return }
            isSearchFocused = false
        }
    }

    private func rangeNavigation(width: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                MacClippyGlassContainer(spacing: 6) {
                    navigationPills
                }
                newCategoryButton
            }
            .fixedSize(horizontal: true, vertical: false)
            scrollableRangeNavigation(width: width)
                .frame(width: width)
        }
    }

    private func scrollableRangeNavigation(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    MacClippyGlassContainer(spacing: 6) {
                        navigationPills
                    }
                }
                .clipped()
                .onChange(of: model.selectedTab, initial: true) { _, tab in
                    proxy.scrollTo(tab, anchor: .center)
                }
                .onChange(of: model.pinboards.map(\.id)) { _, _ in
                    proxy.scrollTo(model.selectedTab, anchor: .center)
                }
                .onChange(of: model.pinboards.map(\.name)) { _, _ in
                    proxy.scrollTo(model.selectedTab, anchor: .center)
                }
                .onChange(of: width) { _, _ in
                    proxy.scrollTo(model.selectedTab, anchor: .center)
                }
            }
            newCategoryButton
        }
    }

    private var navigationPills: some View {
        HStack(spacing: 6) {
            filterPill(title: "History", selected: model.selectedTab == .history, systemImage: "clock") {
                model.selectAllFilter()
            }
            .fixedSize()
            .id(MacClippyDockTab.history)
            filterPill(
                title: "Snippets", selected: model.selectedTab == .snippets, systemImage: "text.quote",
                isDropTarget: dropTargetSnippets, isDropConfirmed: dropConfirmedSnippets
            ) {
                model.selectSnippetsFilter()
            }
            .fixedSize()
            .id(MacClippyDockTab.snippets)
            .onDrop(
                of: clipboardRecordDragTypes, isTargeted: $dropTargetSnippets, perform: handleSnippetDrop)
            ForEach(model.pinboards) { board in
                navigationBoard(board)
                    .id(MacClippyDockTab.pinboard(board.id))
            }
        }
    }

    private func navigationBoard(_ board: MacClippyPinboardEntry) -> some View {
        filterPill(
            title: board.name, selected: model.selectedTab == .pinboard(board.id),
            isDropTarget: dropTargetPinboardID == board.id,
            isDropConfirmed: dropConfirmedPinboardID == board.id, accentHex: board.colorHex
        ) {
            model.selectTab(.pinboard(board.id))
        }
        .frame(maxWidth: 168)
        .help(board.name)
        .contextMenu { pinboardContextMenu(board) }
        .onDrop(
            of: clipboardRecordDragTypes,
            isTargeted: Binding(
                get: { dropTargetPinboardID == board.id },
                set: { dropTargetPinboardID = $0 ? board.id : nil }
            ), perform: { handleDrop($0, on: board) })
    }

    private var filtersButton: some View {
        MacClippyDockChromeIconButton(
            systemImage: "line.3.horizontal.decrease",
            glassID: "searchFilters",
            namespace: headerGlassNamespace,
            reduceMotion: reduceMotion,
            highContrast: highContrast,
            accessibilityLabel: "Search filters",
            accessibilityIdentifier: "macClippy.searchFiltersButton",
            help: model.selectedTab == .snippets
                ? "Search snippet names, triggers and content" : "Filter by type, source app or date",
            action: {
#if MACCLIPPY_E2E
                MacClippyE2EUIInteractionProbe.shared.mark("filter-action")
#endif
                model.isFilterPopoverPresented.toggle()
            },
            selected: !model.searchFilterChips.isEmpty
        )
        .overlay(alignment: .topTrailing) {
            if !model.searchFilterChips.isEmpty {
                Text("\(model.searchFilterChips.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MacClippyDockTheme.textColor)
                    .padding(3)
                    .background(MacClippyDockTheme.panelStrongColor, in: Circle())
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
        }
        .disabled(model.selectedTab == .snippets)
        .accessibilityValue("\(model.searchFilterChips.count) active filters")
        .popover(isPresented: $model.isFilterPopoverPresented, arrowEdge: .top) {
            MacClippyDockSearchFilters(model: model)
#if MACCLIPPY_E2E
                .onAppear { MacClippyE2EUIInteractionProbe.shared.mark("filter-mounted") }
#endif
        }
    }

    private var utilitiesMenu: some View {
        MacClippyDockChromeIconMenu(
            systemImage: "ellipsis", glassID: "moreActions", namespace: headerGlassNamespace,
            reduceMotion: reduceMotion, highContrast: highContrast,
            accessibilityLabel: "More actions", accessibilityIdentifier: "macClippy.moreActionsButton",
            help: "More actions"
        ) {
            Button("New Pinboard…") { model.presentCreateCategory() }
            Button("New Snippet…", action: onCreateSnippet)
            Divider()
            captureMenu
            Divider()
            Button("Shortcuts & Search Help…", action: onOpenHelp)
        }
        .accessibilityValue(captureStatusText ?? "Capture active")
    }

    private var captureStatusText: String? {
        if model.captureStatus.isPaused { return "Paused" }
        let count = model.captureStatus.remainingIgnoredCopies
        return count > 0 ? "Skip \(count)" : nil
    }

    @ViewBuilder
    private var captureMenu: some View {
        if model.captureStatus.isPaused {
            if let until = MacClippyRetentionPreferences.pauseUntil(from: model.defaults),
                until != .distantFuture {
                Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("Capture paused")
            }
            Button("Resume capture") {
                MacClippyRetentionPreferences.applyPause(
                    enabled: false, duration: .untilResumed, defaults: model.defaults)
                model.runtime.applyCapturePausePreference()
            }
        } else {
            Menu("Pause capture") {
                ForEach(MacClippyTimedPauseDuration.allCases, id: \.rawValue) { duration in
                    Button(duration.title) {
                        MacClippyRetentionPreferences.applyPause(
                            enabled: true, duration: duration, defaults: model.defaults)
                        model.runtime.applyCapturePausePreference()
                    }
                }
            }
        }
        Button("Ignore next copy") { model.runtime.ignoreNextCopy() }
        if model.captureStatus.remainingIgnoredCopies > 0 {
            Button("Cancel ignoring next \(model.captureStatus.remainingIgnoredCopies) copies") {
                model.runtime.observer.cancelIgnoredCopies()
            }
        }
    }
}
