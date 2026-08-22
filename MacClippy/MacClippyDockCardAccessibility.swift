import Foundation

import MacClippyCore

extension MacClippyDockView {
    func cardAccessibilityLabel(context: MacClippyClipboardCardContext) -> String {
        var parts: [String] = []
        if let customLabel = context.item.customLabel, !customLabel.isEmpty {
            parts.append(customLabel)
        }
        parts.append(label(for: context.item.contentKind))
        parts.append("from \(context.source.displayName)")
        if let timestamp = MacClippyDockTimestampPolicy.relativeLabel(for: context.item.meta.modified) {
            parts.append(timestamp)
        }
        switch context.item.contentKind {
        case .text, .html, .rtf:
            break
        case .image:
            if let dimensions = context.item.typeMetadataSubtitle {
                parts.append(dimensions)
            }
        case .files:
            parts.append(MacClippyFilePresentation.title(fileCount: context.item.fileURLs.count))
            if let url = context.item.fileURLs.first {
                parts.append(MacClippyFilePresentation.displayName(for: url))
            }
        }
        if let categorySummary = MacClippyDockCardCategoryPolicy.accessibilitySummary(for: context.categories) {
            parts.append(categorySummary)
        }
        return parts.joined(separator: ", ")
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
