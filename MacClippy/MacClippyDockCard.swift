import AppKit
import SwiftUI
import UniformTypeIdentifiers

import MacClippyCore
import MacClippyPlatform

struct MacClippyClipboardCardSnapshot: Equatable, Sendable {
    let itemID: RecordID
    let preview: String
    let contentKind: ContentKind
    let customLabel: String?
    let fileNames: [String]
    let filePaths: [String]
    let typeMetadataSubtitle: String?
    let sourceAppBundleID: String?
    let sourceDisplayName: String
    let modified: Date
    let index: Int
    let dedupRun: Int
    let isSelected: Bool
    let activeBorder: Bool
    let isElevated: Bool
    let categories: [MacClippyDockCategoryPresentation]
    let highlightTerms: [String]
    let isPreviewVisible: Bool
    let sourcePresentationGeneration: UInt
    let showsCategoryIndicator: Bool
    let isRemoteClipboard: Bool
}

struct MacClippyClipboardCardContext: Equatable {
    let item: MacClippyHistoryEntry
    let index: Int
    let source: MacClippySourceAppPresentation
    let dedupRun: Int
    let isSelected: Bool
    let activeBorder: Bool
    let isElevated: Bool
    let categories: [MacClippyDockCategoryPresentation]
    let highlightTerms: [String]
    let isPreviewVisible: Bool
    let sourcePresentationGeneration: UInt
    var showsCategoryIndicator: Bool = false

    var snapshot: MacClippyClipboardCardSnapshot {
        MacClippyClipboardCardSnapshot(
            itemID: item.id,
            preview: item.preview,
            contentKind: item.contentKind,
            customLabel: item.customLabel,
            fileNames: item.fileURLs.map(MacClippyFilePresentation.displayName),
            filePaths: item.fileURLs.map(MacClippyFilePresentation.displayPath),
            typeMetadataSubtitle: item.typeMetadataSubtitle,
            sourceAppBundleID: item.meta.sourceAppBundleID,
            sourceDisplayName: source.displayName,
            modified: item.meta.modified,
            index: index,
            dedupRun: dedupRun,
            isSelected: isSelected,
            activeBorder: activeBorder,
            isElevated: isElevated,
            categories: categories,
            highlightTerms: highlightTerms,
            isPreviewVisible: isPreviewVisible,
            sourcePresentationGeneration: sourcePresentationGeneration,
            showsCategoryIndicator: showsCategoryIndicator,
            isRemoteClipboard: item.isRemoteClipboard
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.snapshot == rhs.snapshot
    }
}

extension MacClippyDockView {
    func snippetCard(_ snippet: MacClippySnippetEntry, index: Int) -> some View {
        let isFocused = index == model.focusedIndex
        let card = Button {
            handleCardClick(
                clickCount: 1, modifiers: currentModifierFlags(), target: .snippet(snippet.id),
                focus: { model.focus(snippet) })
        } label: {
            snippetCardContent(snippet, isFocused: isFocused)
        }
        .buttonStyle(MacClippyCardButtonStyle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            handleCardClick(
                clickCount: 2, modifiers: currentModifierFlags(), target: .snippet(snippet.id),
                focus: { model.focus(snippet) })
        })
        .contextMenu {
            snippetContextMenu(snippet)
        }
        .foregroundStyle(MacClippyDockTheme.textColor)
        .accessibilityLabel(snippetAccessibilityLabel(snippet))
        .accessibilityAddTraits([])

        return card
            .accessibilityAction(named: "Edit") { onEditSnippet(snippet) }
            .accessibilityAction(named: "Paste") {
                focusCard()
                model.pasteTarget(.snippet(snippet.id), completion: onClose)
            }
            .accessibilityAction(named: "Copy") {
                focusCard()
                model.copyTarget(.snippet(snippet.id))
            }
            .accessibilityAction(named: "Preview") {
                focusCard()
                onPreviewTarget(.snippet(snippet.id))
            }
            .accessibilityAction(named: "Delete") {
                focusCard()
                model.deleteSnippet(id: snippet.id)
            }
            .overlay(alignment: .topTrailing) {
                MacClippyCardQuickActions {
                    model.copyTarget(.snippet(snippet.id))
                } more: {
                    snippetContextMenu(snippet)
                }
                .padding(.top, 8).padding(.trailing, 12)
            }
            .modifier(MacClippyCardHoverModifier(enabled: !model.isPreviewVisible, reduceMotion: reduceMotion))
    }

    func card(_ item: MacClippyHistoryEntry, index: Int) -> some View {
        let context = clipboardCardContext(for: item, index: index)
        return cardWithInteractions(
            clipboardCardButton(item: item, index: index, context: context),
            context: context
        )
    }

    private func clipboardCardContext(
        for item: MacClippyHistoryEntry,
        index: Int
    ) -> MacClippyClipboardCardContext {
        let source = MacClippySourceAppResolver.presentation(for: item.meta.sourceAppBundleID)
        let isFocused = index == model.focusedIndex
        let isSelected = model.isSelected(item.id)
        let activeBorder = MacClippyDockCardHighlightPolicy.isActive(
            isFocused: isFocused,
            isSelected: isSelected,
            isPreviewVisible: model.isPreviewVisible
        )

        let categories = model.categories(for: item.id)
        return MacClippyClipboardCardContext(
            item: item,
            index: index,
            source: source,
            dedupRun: model.dedupRunCounts[item.id] ?? 1,
            isSelected: isSelected,
            activeBorder: activeBorder,
            isElevated: isFocused,
            categories: categories,
            highlightTerms: model.highlightTerms,
            isPreviewVisible: model.isPreviewVisible,
            sourcePresentationGeneration: MacClippySourceCardRefreshPolicy.snapshotGeneration(
                cardBundleID: item.meta.sourceAppBundleID,
                generations: sourceResolveBatch.generations
            ),
            showsCategoryIndicator: MacClippyDockCardCategoryPolicy.shouldShowIndicator(
                categories: categories,
                selectedTab: model.selectedTab
            )
        )
    }

    private func clipboardCardButton(
        item: MacClippyHistoryEntry,
        index: Int,
        context: MacClippyClipboardCardContext
    ) -> some View {
        Button {
            handleCardClick(
                clickCount: 1,
                modifiers: currentModifierFlags(),
                target: .item(item.id),
                focus: { model.focusAndSelect(item) },
                selection: selectionHandler(for: item, index: index)
            )
        } label: {
            MacClippyClipboardCardLabel(
                context: context,
                loadThumbnail: { [weak model] id in
                    guard let model else { return nil }
                    return await model.loadImageThumbnail(for: id)
                },
                cachedThumbnail: { [weak model] id in
                    model?.thumbnailLoader.cachedImage(id: id, maxPixelSize: 480)
                }
            )
            .equatable()
        }
        .buttonStyle(MacClippyCardButtonStyle())
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            handleCardClick(
                clickCount: 2, modifiers: currentModifierFlags(), target: .item(item.id),
                focus: { model.focusAndSelect(item) })
        })
        .contextMenu {
            itemContextMenu(item)
        }
        .onDrag {
            cardDragProvider(for: item)
        } preview: {
            MacClippyCardDragPreview(
                context: context,
                thumbnail: cachedCardDragThumbnail(for: item)
            )
        }
    }

    private func cachedCardDragThumbnail(for item: MacClippyHistoryEntry) -> CGImage? {
        switch item.contentKind {
        case .image:
            return model.thumbnailLoader.cachedImage(id: item.id, maxPixelSize: 480)
        case .files:
            guard let url = item.fileURLs.first else { return nil }
            let pointSize: CGSize = MacClippyFilePresentation.mediaKind(for: url) == .image
                ? CGSize(width: MacClippyDockCardMetrics.width, height: MacClippyDockCardMetrics.height)
                : CGSize(width: 96, height: 96)
            return MacClippyFileThumbnailLoader.cachedImage(for: url, pointSize: pointSize)
        case .text, .html, .rtf:
            return nil
        }
    }

    private func selectionHandler(
        for item: MacClippyHistoryEntry,
        index: Int
    ) -> (MacClippyDockSelectionClickPolicy.Action) -> Void {
        { [weak model] action in
            guard let model else { return }
            let clickedIndex = model.visibleItems.firstIndex(where: { $0.id == item.id }) ?? index
            switch action {
            case .focus:
                model.focusSelection(at: clickedIndex)
            case .toggle:
                model.toggleSelection(at: clickedIndex)
            case .extendRange:
                model.extendRange(to: clickedIndex)
            case .copy:
                break
            }
        }
    }

    func cardWithInteractions<Content: View>(
        _ content: Content,
        context: MacClippyClipboardCardContext
    ) -> some View {
        let styled = content
            .foregroundStyle(MacClippyDockTheme.textColor)
            .accessibilityLabel(cardAccessibilityLabel(context: context))
            .accessibilityHint(cardAccessibilityHint(context: context) ?? "")
            .accessibilityAddTraits(context.isSelected ? .isSelected : [])
        return cardAccessibilityActions(styled, context: context)
            .overlay(alignment: .topTrailing) {
                if !model.hasMultipleSelection {
                    MacClippyCardQuickActions {
                        focusCard()
                        model.copyRecord(id: context.item.id)
                    } more: {
                        itemContextMenu(context.item)
                    }
                    .padding(.top, 8).padding(.trailing, 12)
                }
            }
            .modifier(MacClippyCardHoverModifier(enabled: !model.isPreviewVisible, reduceMotion: reduceMotion))
    }
}
