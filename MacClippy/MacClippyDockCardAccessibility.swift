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
            if let subtitle = context.item.typeMetadataSubtitle {
                parts.append(subtitle)
            }
        }
        if let categorySummary = MacClippyDockCardCategoryPolicy.accessibilitySummary(for: context.categories) {
            parts.append(categorySummary)
        }
        return parts.joined(separator: ", ")
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
