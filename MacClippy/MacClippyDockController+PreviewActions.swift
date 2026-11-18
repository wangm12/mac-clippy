import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import SwiftUI

extension MacClippyDockController {
    // Keyboard arrows and preview chevrons share this transition. Only an
    // active secondary surface navigates from its displayed target; the picker
    // advances from its current focus after the surface has closed.
    func moveFocusedPreview(direction: MacClippyDockSelectionDirection) {
        switch interactionMode {
        case .details:
            guard detailsEditing == .none, detailsEditSession?.isSaving != true else { return }
            model.moveFocus(direction, from: detailsTargetID.map(MacClippyDockPreviewTarget.item))
            guard let targetID = model.focusedItem?.id else { return }
            showDetails(targetID: targetID)
        case .preview:
            model.moveFocus(direction, from: previewTarget)
            refreshPreview()
        case .picker:
            model.moveFocus(direction)
        default: break
        }
    }

    func refreshDetails() {
        showDetails(targetID: detailsTargetID)
    }

    // Builds the preview SwiftUI view for a content case, wiring the prev/next
    // navigation callback and the metadata (source icon/name/time/char count)
    // from the focused item. Centralized so the show, refresh, and error paths
    // share the same callback wiring and metadata.

    func previewView(content: MacClippyDockPreviewContent) -> MacClippyDockPreviewView {
        let meta = previewMetadataSnapshot
        let target = previewTarget
        return MacClippyDockPreviewView(
            content: content,
            metadata: meta,
            reduceMotion: shouldReduceMotion,
            onNavigate: { [weak self] direction in
                self?.moveFocusedPreview(direction: direction == .previous ? .left : .right)
            },
            onCopy: { [weak self] in
                guard let target else { return }
                self?.model.copyTarget(target)
            },
            onPaste: { [weak self] in
                guard let target else { return }
                self?.model.pasteTarget(target, completion: { self?.hide() })
            },
            onEdit: previewEditAction(content: content, target: target),
            recognizeOCRLayout: model.runtime.recognizeOCRLayout,
            onCopyText: { [weak self] text in
                self?.copyPreviewText(text)
            },
            onDismiss: { [weak self] in
                self?.hidePreview()
            },
            highlightTerms: model.highlightTerms
        )
    }

    // Resolve QuickLook-style metadata from the focused item: source app
    // presentation, relative timestamp, and character count of the preview.

    private func previewEditAction(
        content: MacClippyDockPreviewContent, target: MacClippyDockPreviewTarget?
    ) -> (() -> Void)? {
        guard let target else { return nil }
        switch target {
        case .snippet(let id):
            guard model.snippets.contains(where: { $0.id == id }) else { return nil }
            return { [weak self] in
                guard let self, let snippet = self.model.snippets.first(where: { $0.id == id }) else { return }
                self.presentSnippetEditor(snippet: snippet)
            }
        case .item:
            switch content {
            case .text, .richText, .color:
                return { [weak self] in self?.showDetails(editing: .content, targetID: target.recordID) }
            default: return nil
            }
        }
    }

    func previewMetadata(for target: MacClippyDockPreviewTarget? = nil) -> MacClippyDockPreviewMetadata {
        let id = (target ?? model.focusedPreviewTarget)?.recordID
        if let details, details.id == id {
            let source = MacClippySourceAppResolver.presentation(for: details.sourceAppBundleID)
            return .init(
                sourceName: source.displayName, sourceIcon: source.icon, sourceAccent: source.accent,
                relativeTime: MacClippyDockTimestampPolicy.relativeLabel(for: details.modified),
                characterCount: details.textContent?.count ?? 0, ocrText: details.ocrText)
        }
        guard let item = model.visibleItems.first(where: { $0.id == id }) else {
            return previewTarget?.recordID == id ? previewMetadataSnapshot : .unknown
        }
        let source = MacClippySourceAppResolver.presentation(for: item.meta.sourceAppBundleID)
        return .init(
            sourceName: source.displayName, sourceIcon: source.icon, sourceAccent: source.accent,
            relativeTime: MacClippyDockTimestampPolicy.relativeLabel(for: item.meta.modified),
            characterCount: item.preview.count, ocrText: item.meta.ocrText)
    }

    func copyPreviewText(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        do {
            try model.runtime.pasteInjector.prepareTextForHistory(normalized)
            showCopyToast(title: "Text copied")
        } catch {
            model.setActionError(MacClippyUserFacingError.message(for: error))
        }
    }

}
