import AppKit
import Foundation
import MacClippyPlatform
import QuartzCore
import os.signpost
import SwiftUI

struct MacClippyDockAnimationTransaction: Equatable {
    enum Operation: Equatable {
        case showing
        case hiding
    }

    let generation: UInt
    let operation: Operation
}

enum MacClippyDockTogglePolicy {
    static func shouldHide(panelIsVisible: Bool) -> Bool {
        panelIsVisible
    }
}

enum MacClippyDockAnimationLifecyclePolicy {
    static func nextGeneration(after generation: UInt) -> UInt {
        generation &+ 1
    }

    static func shouldApplyCompletion(
        for transaction: MacClippyDockAnimationTransaction,
        current: MacClippyDockAnimationTransaction?
    ) -> Bool {
        transaction == current
    }
}

enum MacClippyDockKeyboardOwnershipPolicy {
    static func shouldRestoreKeyboard(
        for mode: MacClippyDockInteractionMode,
        isVisible: Bool,
        isClosing: Bool,
        isExternalWindowPresented: Bool = false
    ) -> Bool {
        guard isVisible, !isClosing, !isExternalWindowPresented else { return false }
        return mode == .picker || mode == .preview || mode == .modal
    }

    static func shouldRestoreFirstResponder(for mode: MacClippyDockInteractionMode) -> Bool {
        mode == .picker || mode == .preview
    }
}

@MainActor
final class MacClippySnippetEditorWindowCoordinator: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func present(onCreate: @escaping (String, String?, String, @escaping (Bool) -> Void) -> Void) {
        if let window {
            bringToFront(window)
            return
        }

        let hostingView = NSHostingView(
            rootView: MacClippyCreateSnippetEditor(
                onCreate: onCreate,
                onCancel: { [weak self] in self?.close() }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 410),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "New Snippet"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.delegate = self
        self.window = window

        window.center()
        bringToFront(window)
    }

    func close() {
        window?.close()
    }

    var isPresented: Bool {
        window?.isVisible == true
    }

    func owns(event: NSEvent) -> Bool {
        event.window === window
    }

    func owns(location: NSPoint) -> Bool {
        guard let window, window.isVisible else { return false }
        return window.frame.contains(location)
    }

    func presentError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Could not save snippet"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in }
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func bringToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

@MainActor
final class MacClippyDockController {
    let model: MacClippyDockModel
    let snippetEditorWindow = MacClippySnippetEditorWindowCoordinator()
    var panel: MacClippyDockPanel?
    var panelContentView: MacClippyDockPanelContentView?
    var hostingView: NSHostingView<MacClippyDockView>?
    var outsideClickMonitor: Any?
    var localClickMonitor: Any?
    var keyMonitor: Any?
    var keyUpMonitor: Any?
    var spaceChangeObserver: NSObjectProtocol?
    var screenParametersObserver: NSObjectProtocol?
    var keyWindowObserver: NSObjectProtocol?
    var ignoreOutsideClicksUntil = Date.distantPast
    var isClosing = false
    var monitorGeneration: UInt = 0
    var animationGeneration: UInt = 0
    var animationTransaction: MacClippyDockAnimationTransaction?
    var previewPanel: MacClippyPreviewPanel?
    var previewHostingView: NSHostingView<MacClippyDockPreviewView>?
    var detailsPanel: MacClippyDetailsPanel?
    var detailsHostingView: NSHostingView<AnyView>?
    var details: MacClippyItemDetails?
    var detailsEditing: MacClippyDetailsEditing = .none
    var previewRequestID: UInt = 0
    var detailsRequestID: UInt = 0
    var previewAnimationGeneration: UInt = 0
    var previewRetryGeneration: UInt = 0
    var previewRetryTask: Task<Void, Never>?
    var previewIsClosing = false
    var previewPerformanceSignpostID: OSSignpostID?
    var interactionMode: MacClippyDockInteractionMode = .picker
    var swiftUIReduceMotion = false
    // Local monitors normally consume picker events before AppKit dispatches
    // them to the panel. The panel remains a fallback for non-key windows and
    // event-routing edge cases, so remember the last consumed event object to
    // make the two paths idempotent without reading deprecated event metadata.
    var lastRoutedEventIdentity: ObjectIdentifier?
    // Screen-level copy toast panel, independent of the dock panel so a copy
    // confirmation survives a dock close and reads as a system indicator.
    var toastPanel: MacClippyToastPanel?
    var toastDismissTask: Task<Void, Never>?

    init(runtime: MacClippyRuntime) {
        model = MacClippyDockModel(runtime: runtime)
    }

    var isVisible: Bool { panel?.isVisible == true && !isClosing }

}

enum MacClippyPreviewFrameMetrics {
    private static let widthFraction: CGFloat = 0.72
    private static let heightFraction: CGFloat = 0.72
    private static let minimumWidth: CGFloat = 560
    private static let minimumHeight: CGFloat = 440
    private static let maximumWidth: CGFloat = 960
    private static let maximumHeight: CGFloat = 720

    static func preferredSize(visibleFrame: CGRect, availableHeight: CGFloat) -> CGSize {
        let width = min(
            maximumWidth,
            max(minimumWidth, visibleFrame.width * widthFraction)
        )
        let height = min(
            maximumHeight,
            max(minimumHeight, availableHeight * heightFraction)
        )
        return CGSize(width: width, height: height)
    }
}

extension CGRect {
    var midPoint: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
