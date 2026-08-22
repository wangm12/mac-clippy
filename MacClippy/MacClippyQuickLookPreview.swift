import AppKit
import QuickLookUI
import SwiftUI

/// Picks a file URL that can fill Space with the same Quick Look engine
/// Finder uses. Missing paths fall back to the filename list.
enum MacClippyDockPreviewFileSurface {
    static func nativePreviewURL(in urls: [URL]) -> URL? {
        existingURLs(in: urls).first
    }
}

/// AppKit `QLPreviewView`, not SwiftUI `VideoPlayer`. The SwiftUI AVKit
/// representable aborts in `getSuperclassMetadata` on current macOS.
struct MacClippyQuickLookPreview: NSViewRepresentable {
    let url: URL
    var autostarts: Bool

    func makeNSView(context: Context) -> MacClippyQuickLookHostView {
        let host = MacClippyQuickLookHostView()
        host.setPreview(url: url, autostarts: autostarts)
        return host
    }

    func updateNSView(_ host: MacClippyQuickLookHostView, context: Context) {
        host.setPreview(url: url, autostarts: autostarts)
    }

    static func dismantleNSView(_ host: MacClippyQuickLookHostView, coordinator: ()) {
        host.teardown()
    }
}

/// SwiftUI keeps the representable mounted across preview navigations.
/// `QLPreviewView` can deactivate when detached, so this host owns a
/// replaceable instance and never reuses a dead preview.
final class MacClippyQuickLookHostView: NSView {
    private var previewView: QLPreviewView?
    private var currentPath: String?
    private var currentAutostarts = false
    private var didAttachToWindow = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            didAttachToWindow = true
            if previewView == nil, let path = currentPath {
                installPreview(path: path, autostarts: currentAutostarts)
            }
            return
        }
        if didAttachToWindow {
            retirePreview()
        }
    }

    func setPreview(url: URL, autostarts: Bool) {
        let path = url.path
        if currentPath == path, previewView != nil {
            previewView?.autostarts = autostarts
            currentAutostarts = autostarts
            return
        }
        currentPath = path
        currentAutostarts = autostarts
        installPreview(path: path, autostarts: autostarts)
    }

    func teardown() {
        retirePreview()
        currentPath = nil
    }

    private func installPreview(path: String, autostarts: Bool) {
        retirePreview()
        guard let preview = QLPreviewView(frame: bounds, style: .normal) else {
            return
        }
        preview.autostarts = autostarts
        preview.shouldCloseWithWindow = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        preview.previewItem = URL(fileURLWithPath: path) as NSURL
        previewView = preview
    }

    private func retirePreview() {
        guard let preview = previewView else { return }
        preview.previewItem = nil
        preview.close()
        preview.removeFromSuperview()
        previewView = nil
    }
}
