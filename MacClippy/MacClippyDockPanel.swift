import AppKit
import QuickLookUI
import SwiftUI

final class MacClippyDockPanelContentView: NSView {
    let backdropView: MacClippyDockBackdropView
    let foregroundView: NSView

    init(foregroundView: NSView) {
        self.backdropView = MacClippyDockBackdropView(frame: .zero)
        self.foregroundView = foregroundView
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        foregroundView.wantsLayer = true
        foregroundView.layer?.backgroundColor = NSColor.clear.cgColor
        foregroundView.layer?.isOpaque = false
        backdropView.autoresizingMask = [.width, .height]
        foregroundView.autoresizingMask = [.width, .height]
        addSubview(backdropView)
        // Apple only applies Regular glass, specular highlights, and
        // vibrancy to `NSGlassEffectView.contentView`. A sibling hosting
        // view sits on top of an empty glass plate and reads as a matte
        // slab with unreadable chrome.
        backdropView.embedForeground(foregroundView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    // The dock is a nonactivating panel. Accept the first click when the panel
    // is regaining key status so AppKit does not consume it only to activate
    // the window; SwiftUI controls should receive that click immediately.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        backdropView.frame = bounds
    }
}

final class MacClippyDockHostingView: NSHostingView<MacClippyDockView> {
    // NSHostingView is the actual hit-tested view for most SwiftUI controls,
    // so the content container's first-mouse policy alone is not sufficient.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        makeTransparent()
    }

    override func layout() {
        super.layout()
        makeTransparent()
    }

    private func makeTransparent() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}

final class MacClippyPreviewHostingView: NSHostingView<MacClippyDockPreviewView> {
    // Preview is a non-activating panel. Accept the first click so starting a
    // drag on a freshly shown screenshot does not get consumed by AppKit while
    // the panel is becoming active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class MacClippyDockBackdropView: NSView {
    private let materialView: NSView
    private let solidFillLayer = CALayer()
    private var reduceTransparencyOverride: Bool?
    private weak var embeddedForeground: NSView?

    override init(frame frameRect: NSRect) {
        materialView = Self.makeMaterialView(frame: frameRect)
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
        layer?.cornerRadius = MacClippyDockBackdropHolePolicy.panelCornerRadius
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        materialView.autoresizingMask = [.width, .height]
        addSubview(materialView)
        solidFillLayer.cornerRadius = MacClippyDockBackdropHolePolicy.panelCornerRadius
        solidFillLayer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.insertSublayer(solidFillLayer, at: 0)
        observeReduceTransparency()
        applyTransparencyPolicy(reduceTransparency: currentReduceTransparency)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isOpaque: Bool { false }

    var isShowingGlass: Bool { !materialView.isHidden }
    var isShowingSolidFill: Bool { !solidFillLayer.isHidden }
    var embedsForegroundInGlass: Bool {
        guard let foreground = embeddedForeground else { return false }
        return glassContentView === foreground && !materialView.isHidden
    }

    func embedForeground(_ view: NSView) {
        embeddedForeground = view
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        installForeground()
    }

    func applyTransparencyPolicy(reduceTransparency: Bool) {
        reduceTransparencyOverride = reduceTransparency
        let useSolid = reduceTransparency
        materialView.isHidden = useSolid
        solidFillLayer.isHidden = !useSolid
        updateSolidFill()
        installForeground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSolidFill()
    }

    override func layout() {
        super.layout()
        materialView.frame = bounds
        solidFillLayer.frame = bounds
        layoutForeground()
    }

    private var currentReduceTransparency: Bool {
        reduceTransparencyOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private func observeReduceTransparency() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAccessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared
        )
    }

    @objc private func handleAccessibilityDisplayOptionsChanged() {
        applyTransparencyPolicy(reduceTransparency: currentReduceTransparency)
    }

    private var glassContentView: NSView? {
        if #available(macOS 26, *), let glass = materialView as? NSGlassEffectView {
            return glass.contentView
        }
        return nil
    }

    private func installForeground() {
        guard let foreground = embeddedForeground else { return }
        if materialView.isHidden {
            clearGlassContent()
            if foreground.superview !== self {
                addSubview(foreground)
            }
            layoutForeground()
            return
        }
        if #available(macOS 26, *), let glass = materialView as? NSGlassEffectView {
            if glass.contentView !== foreground {
                glass.contentView = foreground
            }
            layoutForeground()
            return
        }
        if foreground.superview !== self {
            addSubview(foreground)
        }
        layoutForeground()
    }

    private func clearGlassContent() {
        if #available(macOS 26, *), let glass = materialView as? NSGlassEffectView {
            glass.contentView = nil
        }
    }

    private func layoutForeground() {
        embeddedForeground?.frame = bounds
        if #available(macOS 26, *), let glass = materialView as? NSGlassEffectView {
            glass.contentView?.frame = glass.bounds
        }
    }

    private func updateSolidFill() {
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        solidFillLayer.backgroundColor = isDark
            ? MacClippyDockTheme.bg1Dark.cgColor
            : MacClippyDockTheme.bg1.cgColor
        solidFillLayer.frame = bounds
    }

    private static func makeMaterialView(frame: NSRect) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .regular
            glass.cornerRadius = MacClippyDockBackdropHolePolicy.panelCornerRadius
            glass.clipsToBounds = true
            return glass
        }
        let visual = NSVisualEffectView(frame: frame)
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = MacClippyDockBackdropHolePolicy.panelCornerRadius
        visual.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        return visual
    }
}

final class MacClippyDockPanel: NSPanel {
    var interceptsPickerKeys = false
    var onPickerKey: ((NSEvent) -> Bool)?
    weak var systemQuickLookHost: MacClippySystemQuickLookHosting?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // The dock is opened by a global hotkey but is an interactive
            // surface. It must activate and become the key window so the
            // following Space/arrows/clicks are delivered to this panel rather
            // than back to the app that was active before the hotkey.
            // A nonactivating panel can become key without pulling focus away
            // from a full-screen host app. This is the standard AppKit shape
            // for a global quick-input surface.
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        // Follow the system appearance so Regular glass can sample the
        // desktop. Forcing darkAqua made the plate a black sheet.
        appearance = nil
        // The dock controller animates the content-layer elevation with the panel.
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        // The main-menu level is above full-screen app content while remaining
        // a normal interactive overlay; screenSaver-level windows are reserved
        // for system-style overlays and can produce surprising compositing.
        level = .mainMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
    }

    override func sendEvent(_ event: NSEvent) {
        if interceptsPickerKeys,
           (event.type == .keyDown || event.type == .keyUp),
           onPickerKey?(event) == true {
            return
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated {
            systemQuickLookHost?.acceptsSystemQuickLook(panel) ?? false
        }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            systemQuickLookHost?.beginSystemQuickLook(panel)
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            systemQuickLookHost?.endSystemQuickLook(panel)
        }
    }

}

final class MacClippyPreviewPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The preview panel must receive mouse events so the prev/next chevron
        // buttons in the header can be clicked. Outside-click dismissal still
        // dismisses for clicks elsewhere; the controller excludes clicks inside
        // this panel's frame so a chevron tap never races the dismissal.
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
    }

    // Preview is display-only for keyboard ownership. The Dock panel remains
    // the single key window; all keyboard routing therefore stays in the Dock
    // controller and this display-only panel cannot create a second side-effect
    // path.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

}

// A short-lived floating toast panel for copy confirmations. It is independent
// of the dock panel so a double-click copy shows a screen-level indicator that
// survives even if the dock closes, instead of being trapped inside the dock.
final class MacClippyToastPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // NSPanel may restore this bit for borderless content during init.
        // Remove it explicitly so the toast does not get a full rectangular
        // content backing in any Space.
        styleMask.remove(.fullSizeContentView)
        isOpaque = false
        backgroundColor = .clear
        // Keep the panel's content backing transparent as well. In a
        // full-screen Space AppKit can otherwise composite the content view's
        // rectangular backing behind the SwiftUI capsule.
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        contentView?.layer?.isOpaque = false
        // The toast has no window shadow. A shadow generated by the window
        // server is rectangular and can leak as a box in a full-screen Space.
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        // The main-menu level avoids the rectangular compositor path that can
        // appear for a clear panel in a full-screen Space.
        level = .mainMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
