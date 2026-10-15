import Foundation
import SwiftUI

import MacClippyCore

enum MacClippyDockCardAccessibilityPolicy {
    static func label(for context: MacClippyClipboardCardContext, now: Date = Date()) -> String {
        var parts: [String] = []
        if let customLabel = context.item.customLabel, !customLabel.isEmpty {
            parts.append(customLabel)
        }
        parts.append(contentKindLabel(context.item.contentKind))
        parts.append("from \(context.source.displayName)")
        if context.item.isRemoteClipboard {
            parts.append(MacClippyDockCardRemoteClipboardPolicy.accessibilityPhrase)
        }
        if context.dedupRun > 1 {
            parts.append("\(context.dedupRun) copies")
        }
        if let timestamp = MacClippyDockTimestampPolicy.captionLabel(
            for: context.item.meta.modified,
            now: now
        ) {
            parts.append(timestamp)
        }
        switch context.item.contentKind {
        case .text, .html, .rtf:
            let excerpt = String(context.item.preview.prefix(100))
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if !excerpt.isEmpty { parts.append(excerpt) }
        case .image, .files:
            parts.append(MacClippyDockCardVisibleNamePolicy.text(for: context.item))
        }
        parts.append("Item \(context.index + 1)")
        if let categorySummary = MacClippyDockCardCategoryPolicy.accessibilitySummary(for: context.categories) {
            parts.append(categorySummary)
        }
        return parts.joined(separator: ", ")
    }

    static func contentKindLabel(_ kind: ContentKind) -> String {
        switch kind {
        case .text: "Text"
        case .html: "HTML"
        case .rtf: "Rich text"
        case .image: "Image"
        case .files: "Files"
        }
    }
}

extension MacClippyDockView {
    func cardAccessibilityLabel(context: MacClippyClipboardCardContext) -> String {
        MacClippyDockCardAccessibilityPolicy.label(for: context)
    }

    func cardAccessibilityHint(context: MacClippyClipboardCardContext) -> String? {
        switch context.item.contentKind {
        case .text, .html, .rtf:
            return "Preview to read content"
        case .image, .files:
            return nil
        }
    }

    func snippetAccessibilityLabel(_ snippet: MacClippySnippetEntry) -> String {
        var parts = ["Snippet \(snippet.name)"]
        if let trigger = snippet.trigger, !trigger.isEmpty {
            parts.append("trigger \(trigger)")
        }
        parts.append("\(snippet.body.count) characters")
        return parts.joined(separator: ", ")
    }
}

extension MacClippyDockView {
    func cardAccessibilityActions<Content: View>(
        _ content: Content, context: MacClippyClipboardCardContext
    ) -> some View {
        let actions = content
            .accessibilityAction(named: "Paste") {
                focusCard()
                model.pasteTarget(.item(context.item.id), completion: onClose)
            }
            .accessibilityAction(named: "Copy") {
                focusCard()
                model.copyRecord(id: context.item.id)
            }
            .accessibilityAction(named: "Preview") {
                focusCard()
                onPreviewTarget(.item(context.item.id))
            }
            .accessibilityAction(named: "Rename") {
                model.focus(context.item)
                model.presentRenameItem(for: context.item)
            }
            .accessibilityAction(named: model.pinboards.isEmpty ? "Create list" : "Pin to list") {
                focusCard()
                model.focusAndSelect(context.item)
                if !model.pinboards.isEmpty {
                    model.requestPinSelection(ids: [context.item.id])
                } else {
                    model.presentCreateCategory()
                }
            }
            .accessibilityAction(named: "Delete") {
                focusCard()
                model.focusAndSelect(context.item)
                model.requestDeleteRecords(ids: [context.item.id])
            }
            .accessibilityAction(named: "Details") {
                onShowDetails(context.item.id, false)
            }
        return textAccessibilityActions(actions, item: context.item)
    }

    @ViewBuilder
    private func textAccessibilityActions<Content: View>(
        _ content: Content, item: MacClippyHistoryEntry
    ) -> some View {
        if item.supportsPlainCopy {
            content
                .accessibilityAction(named: "Copy plain") { model.copyRecord(id: item.id, plain: true) }
                .accessibilityAction(named: "Edit") { onShowDetails(item.id, true) }
        } else {
            content
        }
    }
}
