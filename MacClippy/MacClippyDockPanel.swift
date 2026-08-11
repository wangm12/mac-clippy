import AppKit
import SwiftUI

final class MacClippyDockPanelContentView: NSView {
    let backdropView: MacClippyDockBackdropView
    let foregroundView: NSView

    init(foregroundView: NSView) {
        self.backdropView = MacClippyDockBackdropView(frame: .zero)
        self.foregroundView = foregroundView
        super.init(frame: .zero)

        wantsLayer = true
        foregroundView.wantsLayer = true
        backdropView.autoresizingMask = [.width, .height]
        foregroundView.autoresizingMask = [.width, .height]
        addSubview(backdropView)
        addSubview(foregroundView)
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
        foregroundView.frame = bounds
    }
}

final class MacClippyDockHostingView: NSHostingView<MacClippyDockView> {
    // NSHostingView is the actual hit-tested view for most SwiftUI controls,
    // so the content container's first-mouse policy alone is not sufficient.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class MacClippyPreviewHostingView: NSHostingView<MacClippyDockPreviewView> {
    // Preview is a non-activating panel. Accept the first click so starting a
    // drag on a freshly shown screenshot does not get consumed by AppKit while
    // the panel is becoming active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class MacClippyDockBackdropView: NSView {
    private let gradientLayer = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Non-opaque so the warm gradient + panel material can show through the
        // rounded top corners and the vibrancy underneath.
        layer?.backgroundColor = NSColor.clear.cgColor
        updateGradient()
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGradient()
    }

    override func updateLayer() {
        updateGradient()
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds
    }

    private func updateGradient() {
        // Warm beige -> cream (light) or lifted warm (dark) panel fill. The
        // foreground SwiftUI layer adds the vibrancy/material on top.
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        gradientLayer.colors = isDark
            ? [MacClippyDockTheme.bg0Dark.cgColor, MacClippyDockTheme.bg1Dark.cgColor]
            : [MacClippyDockTheme.bg0.cgColor, MacClippyDockTheme.bg1.cgColor]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 0, y: 1)
        if gradientLayer.superlayer == nil {
            layer?.insertSublayer(gradientLayer, at: 0)
        }
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 22
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.isOpaque = false
    }
}

final class MacClippyDockPanel: NSPanel {
    var interceptsPickerKeys = false
    var onPickerKey: ((NSEvent) -> Bool)?

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
