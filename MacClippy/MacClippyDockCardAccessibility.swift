import Foundation

import MacClippyCore

enum MacClippyDockCardAccessibilityPolicy {
    static func label(for context: MacClippyClipboardCardContext, now: Date = Date()) -> String {
        var parts: [String] = []
        if let customLabel = context.item.customLabel, !customLabel.isEmpty {
            parts.append(customLabel)
        }
        parts.append(contentKindLabel(context.item.contentKind))
        parts.append("from \(context.source.displayName)")
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
