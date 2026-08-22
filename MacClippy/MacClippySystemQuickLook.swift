import AppKit
import Foundation
import MacClippyCore
import QuickLookUI

/// Finder file copies that still exist on disk open the system Space panel.
/// Text, snippets, colors, and screenshot pixels stay on the in-app preview.
enum MacClippySystemQuickLookPolicy {
    static func existingFileURLs(in urls: [URL]) -> [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func prefersSystemQuickLook(
        contentKind: ContentKind,
        fileURLs: [URL]
    ) -> Bool {
        guard contentKind == .files else { return false }
        let existing = existingFileURLs(in: fileURLs)
        guard !existing.isEmpty else { return false }
        // Images and movies stay in the non-key overlay. QLPreviewPanel
        // becomes key, can change Spaces, and freezes fullscreen hosts.
        return existing.contains { MacClippyFilePresentation.mediaKind(for: $0) == .other }
    }
}

enum MacClippySystemQuickLookPresentAction: Equatable {
    case open
    case reload
}

enum MacClippySystemQuickLookPresentationPolicy {
    static func action(panelIsVisible: Bool) -> MacClippySystemQuickLookPresentAction {
        panelIsVisible ? .reload : .open
    }

    static func shouldTakeDockKeyboard(for action: MacClippySystemQuickLookPresentAction) -> Bool {
        false
    }

    static func shouldExitPreviewOnEnd(
        isProgrammaticClose: Bool,
        customPreviewVisible: Bool
    ) -> Bool {
        !isProgrammaticClose && !customPreviewVisible
    }
}

enum MacClippyPreviewSurfaceTransition: Equatable {
    case openSession
    case switchSurface
    case closeSession
}

enum MacClippyPreviewSurfacePolicy {
    static func transition(isOpening: Bool) -> MacClippyPreviewSurfaceTransition {
        isOpening ? .openSession : .switchSurface
    }

    static func shouldAnimateSystemQuickLook(for transition: MacClippyPreviewSurfaceTransition) -> Bool {
        transition != .switchSurface
    }

    static func shouldResetCustomPreviewToLoading(for transition: MacClippyPreviewSurfaceTransition) -> Bool {
        transition == .closeSession
    }

    static func keyboardOwnershipRetryLimit(for transition: MacClippyPreviewSurfaceTransition) -> Int {
        transition == .switchSurface ? 0 : 3
    }

    static func quickLookAnimationBehavior(animated: Bool) -> NSWindow.AnimationBehavior {
        animated ? .default : .none
    }
}

enum MacClippySystemQuickLookEventPolicy {
    static func shouldHandleInPicker(keyCode: UInt16) -> Bool {
        switch keyCode {
        case 123, 124, 49, 36, 76, 53:
            return true
        default:
            return false
        }
    }
}

@MainActor
protocol MacClippySystemQuickLookHosting: AnyObject {
    func acceptsSystemQuickLook(_ panel: QLPreviewPanel) -> Bool
    func beginSystemQuickLook(_ panel: QLPreviewPanel)
    func endSystemQuickLook(_ panel: QLPreviewPanel)
}

/// Data source for the shared `QLPreviewPanel`. The panel does not retain
/// its data source, so the dock controller keeps this object alive.
final class MacClippySystemQuickLookSession: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private(set) var urls: [URL] = []
    nonisolated(unsafe) var handlePickerEvent: ((NSEvent) -> Bool)?

    func setURLs(_ urls: [URL]) {
        self.urls = urls
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        let url = urls[index]
        return url as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel, handle event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp,
              MacClippySystemQuickLookEventPolicy.shouldHandleInPicker(keyCode: event.keyCode) else {
            return false
        }
        return handlePickerEvent?(event) ?? false
    }
}

extension MacClippyDockPreviewFileSurface {
    static func existingURLs(in urls: [URL]) -> [URL] {
        MacClippySystemQuickLookPolicy.existingFileURLs(in: urls)
    }

    static func prefersSystemQuickLook(contentKind: ContentKind, fileURLs: [URL]) -> Bool {
        MacClippySystemQuickLookPolicy.prefersSystemQuickLook(
            contentKind: contentKind,
            fileURLs: fileURLs
        )
    }
}
