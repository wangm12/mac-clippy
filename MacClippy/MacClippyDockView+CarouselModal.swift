import AppKit
import SwiftUI

extension MacClippyDockView {
    @ViewBuilder
    var modalOverlay: some View {
        if let modal = model.modal {
            ZStack {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if case .confirmDeleteCategory = modal {
                            model.dismissModal()
                        }
                    }
                switch modal {
                case let .createCategory(token):
                    MacClippyCreateCategoryEditor { name, color, completion in
                        model.createPinboard(name: name, color: color) { succeeded in
                            if succeeded {
                                model.dismissModal()
                            }
                            completion(succeeded)
                        }
                    } onCancel: {
                        model.dismissModal()
                    }
                    .id(token)
                case let .renameItem(recordID, initialName, token):
                    MacClippyRenameItemEditor(initialName: initialName) { result in
                        if case let .save(name) = result {
                            model.renameItem(id: recordID, name: name)
                        }
                        model.dismissModal()
                    } onCancel: {
                        model.dismissModal()
                    }
                    .id(token)
                case let .renameCategory(pinboardID, token):
                    Group {
                        if let pinboard = model.pinboards.first(where: { $0.id == pinboardID }) {
                            MacClippyRenameCategoryEditor(initialName: pinboard.name) { name in
                                model.renamePinboard(pinboard, to: name)
                                model.dismissModal()
                            } onCancel: {
                                model.dismissModal()
                            }
                        } else {
                            Color.clear.onAppear { model.dismissModal() }
                        }
                    }
                    .id(token)
                case let .confirmDeleteCategory(pinboardID, name, token):
                    Group {
                        if let pinboard = model.pinboards.first(where: { $0.id == pinboardID }) {
                            MacClippyConfirmDeleteCategoryEditor(categoryName: name) {
                                model.deletePinboard(pinboard)
                                model.dismissModal()
                            } onCancel: {
                                model.dismissModal()
                            }
                        } else {
                            Color.clear.onAppear { model.dismissModal() }
                        }
                    }
                    .id(token)
                }
            }
            .transition(MacClippyMotion.fadeTransition(reduceMotion: reduceMotion))
            .animation(MacClippyMotion.animation(MacClippyMotion.contentAnimation, reduceMotion: reduceMotion), value: model.modal)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityFocused($modalAccessibilityFocused)
            .accessibilityLabel(modalAccessibilityLabel(for: modal))
        }
    }

    func modalAccessibilityLabel(for modal: MacClippyDockModal) -> String {
        switch modal {
        case .createCategory:
            return "New category dialog"
        case .renameItem:
            return "Rename clipboard item dialog"
        case .renameCategory:
            return "Rename category dialog"
        case .confirmDeleteCategory:
            return "Delete category confirmation dialog"
        }
    }

    func announceSearchResultsIfNeeded() {
        let isLoading: Bool
        let hasMore: Bool
        let count: Int
        switch model.selectedTab {
        case .history:
            isLoading = model.isLoading
            hasMore = model.historyHasMore
            count = model.visibleItems.count
        case .pinboard:
            isLoading = model.pinboardSearchIsLoading
            hasMore = model.pinboardSearchHasMore
            count = model.visibleItems.count
        case .snippets:
            isLoading = false
            hasMore = false
            count = model.visibleSnippets.count
        }
        guard let announcement = MacClippyDockSearchAnnouncementPolicy.announcement(
            query: model.query,
            tab: model.selectedTab,
            count: count,
            hasMore: hasMore,
            isLoading: isLoading
        ) else { return }
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
            notification: .announcementRequested,
            userInfo: [.announcement: announcement]
        )
    }

    @ViewBuilder
    var carousel: some View {
        carouselContent
            .transition(MacClippyMotion.contentTransition(reduceMotion: reduceMotion))
            .animation(MacClippyMotion.animation(MacClippyMotion.contentAnimation, reduceMotion: reduceMotion), value: model.selectedTab)
    }

    @ViewBuilder
    private var carouselContent: some View {
        let visibleItems = model.visibleItems
        let visibleSnippets = model.visibleSnippets
        if model.isLoading && visibleItems.isEmpty && visibleSnippets.isEmpty {
            ProgressView()
                .controlSize(.small)
                .tint(MacClippyDockTheme.accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading clipboard history")
        } else if let errorMessage = model.historyLoadError, visibleItems.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MacClippyDockTheme.accentColor)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(MacClippyDockTheme.mutedColor)
                    .multilineTextAlignment(.center)
                Button("Retry", action: { model.reload() })
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let pageError = model.pageError, visibleItems.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MacClippyDockTheme.accentColor)
                Text(pageError)
                    .font(.caption)
                    .foregroundStyle(MacClippyDockTheme.mutedColor)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    if model.selectedTab == .history {
                        model.retryCurrentPage()
                    } else {
                        model.retryCurrentPage()
                    }
                }
                .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.selectedTab == .snippets {
            snippetCarousel
        } else if visibleItems.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.title3)
                    .foregroundStyle(MacClippyDockTheme.muted2Color)
                Text(emptyTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MacClippyDockTheme.textColor)
                Text(emptySubtitle)
                    .font(.caption)
                    .foregroundStyle(MacClippyDockTheme.mutedColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: MacClippyDockCardMetrics.gap) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            card(item, index: index)
                                .id(item.id)
                                .transition(MacClippyMotion.cardListTransition(reduceMotion: reduceMotion))
                                .onAppear {
                                    model.loadMoreHistoryIfNeeded(after: item.id)
                                    model.loadMorePinboardIfNeeded(after: item.id)
                                    model.loadMorePinboardSearchIfNeeded(after: item.id)
                                }
                        }
                        if let pageError = model.pageError {
                            pageRetryFooter(
                                message: pageError,
                                action: model.retryCurrentPage
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, MacClippyDockCardMetrics.carouselVerticalPadding)
                }
                // Only keyboard/preview navigation follows the focused card.
                // Pointer selection leaves the carousel at its current scroll
                // position so clicking never recenters or reorders the list.
                .onChange(of: model.focusFollowRequestID) { _, _ in
                    guard let targetID = model.focusFollowTargetID,
                          visibleItems.contains(where: { $0.id == targetID }) else { return }
                    if reduceMotion {
                        proxy.scrollTo(targetID, anchor: .center)
                    } else {
                        withAnimation(MacClippyMotion.focusFollowSpring) {
                            proxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                }
            }
            // Constrain the horizontal carousel to the compact card height plus
            // its vertical scroll padding so it never stretches to fill the
            // panel vertically and leaves a large blank gap below the cards.
            .frame(height: MacClippyDockCardMetrics.carouselHeight(for: dynamicTypeSize))
            .overlay { carouselEdgeFade }
            .overlay { MacClippyDockScrollSignpostProbe().allowsHitTesting(false) }
        }
    }

    private var carouselEdgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [
                    MacClippyDockTheme.panelStrongColor,
                    MacClippyDockTheme.panelStrongColor.opacity(0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 16)
            Spacer(minLength: 0)
            LinearGradient(
                colors: [
                    MacClippyDockTheme.panelStrongColor.opacity(0),
                    MacClippyDockTheme.panelStrongColor
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 16)
        }
        .allowsHitTesting(false)
    }

    private func pageRetryFooter(message: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(MacClippyDockTheme.accentColor)
            Text(message)
                .font(.caption)
                .foregroundStyle(MacClippyDockTheme.mutedColor)
                .multilineTextAlignment(.center)
            Button("Retry", action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(width: MacClippyDockCardMetrics.width * 0.82)
        .padding(.horizontal, 10)
    }

    private var snippetCarousel: some View {
        let visibleSnippets = model.visibleSnippets
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MacClippyDockCardMetrics.gap) {
                    snippetAddCard

                    if visibleSnippets.isEmpty, !model.snippets.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.title3)
                                .foregroundStyle(MacClippyDockTheme.muted2Color)
                            Text(MacClippyDockEmptyStateCopy.snippetTitle(query: model.query))
                                .font(.callout.weight(.medium))
                                .foregroundStyle(MacClippyDockTheme.textColor)
                            Text(MacClippyDockEmptyStateCopy.snippetSubtitle(query: model.query))
                                .font(.caption)
                                .foregroundStyle(MacClippyDockTheme.mutedColor)
                        }
                        .frame(
                            width: MacClippyDockCardMetrics.width,
                            height: MacClippyDockCardMetrics.height(for: dynamicTypeSize)
                        )
                    } else {
                        ForEach(Array(visibleSnippets.enumerated()), id: \.element.id) { index, snippet in
                            snippetCard(snippet, index: index)
                                .id(snippet.id)
                                .transition(MacClippyMotion.cardListTransition(reduceMotion: reduceMotion))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, MacClippyDockCardMetrics.carouselVerticalPadding)
            }
            // Same keyboard/preview-only focus-follow behavior as the
            // clipboard carousel; pointer selection never recenters it.
            .onChange(of: model.focusFollowRequestID) { _, _ in
                guard let targetID = model.focusFollowTargetID,
                      visibleSnippets.contains(where: { $0.id == targetID }) else { return }
                if reduceMotion {
                    proxy.scrollTo(targetID, anchor: .center)
                } else {
                    withAnimation(MacClippyMotion.focusFollowSpring) {
                        proxy.scrollTo(targetID, anchor: .center)
                    }
                }
            }
        }
        // Keep the snippet carousel the same compact height as the clipboard
        // carousel, including when the add card is the only card.
        .frame(height: MacClippyDockCardMetrics.carouselHeight(for: dynamicTypeSize))
        .overlay { carouselEdgeFade }
        .overlay { MacClippyDockScrollSignpostProbe().allowsHitTesting(false) }
    }

    private var snippetAddCard: some View {
        Button {
            onCreateSnippet()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(MacClippyDockTheme.accentColor)
                    .frame(width: 42, height: 42)
                    .background(MacClippyDockTheme.accentSoftColor, in: Circle())
                Text("Add snippet")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MacClippyDockTheme.textColor)
                Text("Create reusable text")
                    .font(.caption)
                    .foregroundStyle(MacClippyDockTheme.mutedColor)
            }
            .frame(width: MacClippyDockCardMetrics.width, height: MacClippyDockCardMetrics.height(for: dynamicTypeSize))
            .contentShape(RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous))
            .background(MacClippyDockTheme.cardColor, in: RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous)
                    .stroke(
                        MacClippyDockTheme.accentColor.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add snippet")
        .accessibilityHint("Create a reusable text snippet")
    }
}
