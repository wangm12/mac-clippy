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
            sourcePresentationGeneration: sourcePresentationGeneration
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
            handleCardClick(clickCount: 1, modifiers: currentModifierFlags(), focus: { model.focus(snippet) })
        } label: {
            snippetCardContent(snippet, isFocused: isFocused)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            handleCardClick(clickCount: 2, modifiers: currentModifierFlags(), focus: { model.focus(snippet) })
        })
        .contextMenu {
            snippetContextMenu(snippet)
        }
        .foregroundStyle(MacClippyDockTheme.textColor)
        .modifier(MacClippyCardHoverModifier(enabled: !model.isPreviewVisible, reduceMotion: reduceMotion))
        .accessibilityLabel(snippetAccessibilityLabel(snippet))
        .accessibilityAddTraits([])

        return card
            .accessibilityAction(named: "Paste") {
                focusCard()
                model.focus(snippet)
                model.pasteFocused(completion: onClose)
            }
            .accessibilityAction(named: "Copy") {
                focusCard()
                model.focus(snippet)
                model.copyFocused()
            }
            .accessibilityAction(named: "Preview") {
                focusCard()
                model.focus(snippet)
                onPreview()
            }
            .accessibilityAction(named: "Delete") {
                focusCard()
                model.focus(snippet)
                model.deleteFocused()
            }
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

        return MacClippyClipboardCardContext(
            item: item,
            index: index,
            source: source,
            dedupRun: model.dedupRunCounts[item.id] ?? 1,
            isSelected: isSelected,
            activeBorder: activeBorder,
            isElevated: isFocused,
            categories: model.categories(for: item.id),
            highlightTerms: MacClippySearchGrammar.parse(model.query).bareTerms,
            isPreviewVisible: model.isPreviewVisible,
            sourcePresentationGeneration: sourcePresentationGeneration
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
                focus: { model.focusAndSelect(item) },
                selection: selectionHandler(for: item, index: index)
            )
        } label: {
            MacClippyClipboardCardLabel(
                context: context,
                loadThumbnail: { [weak model] id in
                    guard let model else { return nil }
                    return await model.loadImageThumbnail(for: id)
                }
            )
            .equatable()
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            handleCardClick(clickCount: 2, modifiers: currentModifierFlags(), focus: { model.focusAndSelect(item) })
        })
        .contextMenu {
            itemContextMenu(item)
        }
        .onDrag {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.utf8PlainText.identifier,
                visibility: .all
            ) { completion in
                completion(item.id.rawValue.data(using: .utf8), nil)
                return nil
            }
            return provider
        } preview: {
            Text(item.preview.isEmpty ? "Clipboard item" : item.preview)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(MacClippyDockTheme.textColor)
                .padding(.horizontal, 10)
                .frame(width: 180, height: 32, alignment: .leading)
                .background(
                    MacClippyDockTheme.cardColor.opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .opacity(0.72)
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
        content
            .foregroundStyle(MacClippyDockTheme.textColor)
            .modifier(MacClippyCardHoverModifier(enabled: !model.isPreviewVisible, reduceMotion: reduceMotion))
            .accessibilityLabel(cardAccessibilityLabel(context: context))
            .accessibilityHint(cardAccessibilityHint(context: context) ?? "")
            .accessibilityAddTraits(context.isSelected ? .isSelected : [])
            .accessibilityAction(named: "Paste") {
                focusCard()
                model.focusAndSelect(context.item)
                model.pasteFocused(completion: onClose)
            }
            .accessibilityAction(named: "Copy") {
                focusCard()
                model.focusAndSelect(context.item)
                model.copyFocused()
            }
            .accessibilityAction(named: "Preview") {
                focusCard()
                model.focusAndSelect(context.item)
                onPreview()
            }
            .accessibilityAction(named: "Copy plain") {
                guard context.item.supportsPlainCopy else { return }
                focusCard()
                model.focusAndSelect(context.item)
                model.copyFocused(plain: true)
            }
            .accessibilityAction(named: "Rename") {
                model.focus(context.item)
                model.presentRenameItem(for: context.item)
            }
            .accessibilityAction(named: model.pinboards.isEmpty ? "Create list" : "Pin to list") {
                focusCard()
                model.focusAndSelect(context.item)
                if let firstPinboard = model.pinboards.first {
                    model.togglePinFocused(in: firstPinboard.id)
                } else {
                    model.presentCreateCategory()
                }
            }
            .accessibilityAction(named: "Delete") {
                focusCard()
                model.focusAndSelect(context.item)
                model.deleteFocused()
            }
    }
}
