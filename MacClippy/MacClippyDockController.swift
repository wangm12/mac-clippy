import AppKit
import Foundation
import MacClippyPlatform
import MacClippyCore
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

enum MacClippyDockToggleSource: Equatable {
    case hotKey
    case statusItem
}

enum MacClippyDockToggleAction: Equatable {
    case show
    case hide
    case ignore
}

enum MacClippyDockTogglePolicy {
    static func shouldHide(panelIsVisible: Bool) -> Bool {
        panelIsVisible
    }

    static func action(
        source: MacClippyDockToggleSource,
        panelIsVisible: Bool,
        isClosing: Bool,
        isDifferentScreen: Bool = false
    ) -> MacClippyDockToggleAction {
        if isClosing {
            // The status-item mouseDown already hid the panel through the
            // local outside-click monitor. Reopening that same click flashes.
            // A hotkey during the exit animation is a new explicit open.
            return source == .hotKey ? .show : .ignore
        }
        if source == .hotKey && panelIsVisible && isDifferentScreen {
            return .show
        }
        return panelIsVisible ? .hide : .show
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
        isExternalWindowPresented: Bool = false,
        isSystemQuickLookVisible: Bool = false
    ) -> Bool {
        guard isVisible, !isClosing, !isExternalWindowPresented, !isSystemQuickLookVisible else {
            return false
        }
        return mode == .picker || mode == .preview || mode == .modal || mode == .search
    }

    static func shouldRestoreFirstResponder(for mode: MacClippyDockInteractionMode) -> Bool {
        mode == .picker || mode == .preview
    }

    static func shouldTakeKeyboardOwnership(isSystemQuickLookVisible: Bool) -> Bool {
        !isSystemQuickLookVisible
    }
}

@MainActor
final class MacClippySnippetEditorWindowCoordinator: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var form: MacClippySnippetEditorState?
    private(set) var generation: UInt = 0

    func present(
        snippet: MacClippySnippetEntry? = nil,
        onCreate: @escaping (String, String?, String, String?, @escaping (Bool) -> Void) -> Void
    ) {
        if let window {
            bringToFront(window)
            return
        }

        let form = MacClippySnippetEditorState(snippet: snippet)
        generation &+= 1
        self.form = form
        let hostingView = NSHostingView(
            rootView: MacClippyCreateSnippetEditor(
                form: form,
                onCreate: onCreate,
                onCancel: { [weak self] in self?.window?.performClose(nil) }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 468),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = snippet == nil ? "New Snippet" : "Edit Snippet"
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
        form?.errorMessage = message
    }

    func windowWillClose(_ notification: Notification) {
        generation &+= 1
        window = nil
        form = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard form?.isSubmitting != true else { return false }
        guard form?.isDirty == true else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Your snippet edits have not been saved."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        return alert.runModal() == .alertFirstButtonReturn
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
    let openSettingsHandler: @MainActor () -> Void
    let snippetEditorWindow = MacClippySnippetEditorWindowCoordinator()
    var panel: MacClippyDockPanel?
    var panelContentView: MacClippyDockPanelContentView?
    var hostingView: NSHostingView<MacClippyDockView>?
    var outsideClickMonitor: Any?
    var localClickMonitor: Any?
    var keyMonitor: Any?
    var keyUpMonitor: Any?
    var spaceChangeObserver: NSObjectProtocol?
    var keyWindowObserver: NSObjectProtocol?
    var keyboardInputSourceObserver: NSObjectProtocol?
    var cachedKeyboardInputSourceType: String?
    var pasteTargetApplication: NSRunningApplication? {
        didSet { model.pasteTargetProcessIdentifier = pasteTargetApplication?.processIdentifier }
    }
    var didActivateApplicationForSearch = false
    var isFullscreenSearchHost = false
    var pendingDisplayEvent: MacClippyDisplayLifecycleEvent?
    var skipGlassMotionForSession = false
    var ignoreOutsideClicksUntil = Date.distantPast
    var ignoreSpaceChangesUntil = Date.distantPast
    var statusItemScreenFrame: (() -> CGRect?)?
    var isClosing = false
    var didOrderOutBeforePaste = false
    var monitorGeneration: UInt = 0
    var animationGeneration: UInt = 0
    var animationTransaction: MacClippyDockAnimationTransaction?
    var previewPanel: MacClippyPreviewPanel?
    var previewHostingView: NSHostingView<MacClippyDockPreviewView>?
    let systemQuickLookSession = MacClippySystemQuickLookSession()
    var isSystemQuickLookVisible = false
    var isClosingSystemQuickLook = false
    var detailsPanel: MacClippyDetailsPanel?
    var detailsHostingView: NSHostingView<AnyView>?
    var details: MacClippyItemDetails?
    var detailsEditing: MacClippyDetailsEditing = .none
    var detailsEditSession: MacClippyDetailsEditSession?
    var detailsTargetID: RecordID?
    var previewRequestID: UInt = 0
    var previewTarget: MacClippyDockPreviewTarget?
    var previewMetadataSnapshot = MacClippyDockPreviewMetadata.unknown
    var detailsRequestID: UInt = 0
    var detailsIsLoading = false
    var previewAnimationGeneration: UInt = 0
    var previewRetryGeneration: UInt = 0
    var previewRetryTask: Task<Void, Never>?
    var previewIsClosing = false
    var previewPerformanceSignpostID: OSSignpostID?
    #if MACCLIPPY_E2E
    var e2eFocusDiagnostic: ((String) -> Void)?
    #endif
    var interactionMode: MacClippyDockInteractionMode = .picker
    var swiftUIReduceMotion = false
    var reduceMotionOverride: Bool?
    // Local monitors normally consume picker events before AppKit dispatches
    // them to the panel. The panel remains a fallback for non-key windows and
    // event-routing edge cases, so remember the last consumed event object to
    // make the two paths idempotent without reading deprecated event metadata.
    var lastRoutedEventIdentity: ObjectIdentifier?
    var nativeMenuTrackingDepth = 0
    var nativeMenuObservers: [MacClippyNotificationToken] = []
    // Screen-level copy toast panel, independent of the dock panel so a copy
    // confirmation survives a dock close and reads as a system indicator.
    var toastPanel: MacClippyToastPanel?
    var toastDismissTask: Task<Void, Never>?
    var toastGeneration: UInt = 0

    init(
        runtime: MacClippyRuntime, defaults: UserDefaults = .standard,
        onOpenSettings: @escaping @MainActor () -> Void = { MacClippySettingsWindowCoordinator.shared.bringToFront() }
    ) {
        model = MacClippyDockModel(runtime: runtime, defaults: defaults)
        openSettingsHandler = onOpenSettings
        configureModelCallbacks()
        configureBeforePasteHook()
        observeNativeMenus()
    }

    private func configureModelCallbacks() {
        model.actionToastHandler = { [weak self] feedback in
            self?.showCopyToast(title: feedback.title, duration: feedback.toastDuration)
        }
        model.snippetUpdateHandler = { [weak self] id in
            guard let self, self.panel?.isVisible == true,
                  self.interactionMode == .preview, self.previewTarget == .snippet(id) else { return }
            self.refreshPreview(for: .snippet(id))
        }
        model.actionErrorHandler = { [weak self] message in
            guard let self, self.interactionMode == .details else { return }
            self.detailsEditSession?.errorMessage = message
        }
    }

    private func configureBeforePasteHook() {
#if !MACCLIPPY_E2E
        model.beforePasteHook = { [weak controller = self] in
            let transition = Self.beforePasteTransition(for: controller)
            guard transition.shouldContinue else { return false }
            if let pid = transition.targetPID {
                for _ in 0..<8 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            return true
        }
#endif
    }

#if !MACCLIPPY_E2E
    private nonisolated static func beforePasteTransition(
        for controller: MacClippyDockController?
    ) -> (shouldContinue: Bool, targetPID: Int32?) {
        guard !MacClippyMainHop.isCapturingForTesting, let controller else {
            return (true, nil)
        }
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                controller.prepareVisualTransitionBeforePaste()
            }
        }
        let box = BeforePasteTransitionBox()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let value = MainActor.assumeIsolated {
                controller.prepareVisualTransitionBeforePaste()
            }
            box.set(value)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 0.08) == .timedOut {
            return (true, nil)
        }
        return box.get()
    }
#endif

    private func observeNativeMenus() {
        for (name, delta) in [(NSMenu.didBeginTrackingNotification, 1), (NSMenu.didEndTrackingNotification, -1)] {
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.nativeMenuTrackingDepth = max(0, self.nativeMenuTrackingDepth + delta)
                }
            }
            nativeMenuObservers.append(MacClippyNotificationToken(observer))
        }
    }

    var isVisible: Bool { panel?.isVisible == true && !isClosing }

    func rebuildVisibleGlassSurfaces() {
        guard isVisible, !isClosing else { return }
        guard let screen = screenContainingCursor() ?? NSScreen.main else { return }
        model.prepareForSurfaceRebuild()
        stopMonitors()
        discardPanelSurfaces()
        let frame = MacClippyDockFramePolicy.frame(
            for: screen.frame,
            hasMultipleSelection: model.hasMultipleSelection
        )
        let dockPanel = makeDockPanel(frame: frame)
        dockPanel.contentView?.frame = NSRect(origin: .zero, size: frame.size)
        dockPanel.contentView?.autoresizingMask = [.width, .height]
        dockPanel.setFrame(frame, display: false, animate: false)
        configurePanelLayer(dockPanel)
        resetPanelAnimationState(dockPanel)
        setPanelLayerState(
            dockPanel,
            backdropOpacity: 1,
            foregroundOpacity: 1,
            scale: 1,
            shadowOpacity: MacClippyMotion.panelShadowOpacity
        )
        dockPanel.interceptsPickerKeys = true
        dockPanel.makeKeyAndOrderFront(nil)
        takeKeyboardOwnership(of: dockPanel)
        startMonitors()
        handleScreenParametersChanged()
    }

#if !MACCLIPPY_E2E
    func prepareVisualTransitionBeforePaste() -> (shouldContinue: Bool, targetPID: Int32?) {
        _ = MacClippyPasteInjector.refreshPasteVirtualKeyCodeOnMain()
        guard panel?.isVisible == true else { return (true, nil) }
        didOrderOutBeforePaste = true
        panel?.orderOut(nil)
        didActivateApplicationForSearch = false
        guard let host = pasteTargetApplication,
              !host.isTerminated,
              host != NSRunningApplication.current else {
            return (true, nil)
        }
        if host.isActive {
            return (true, nil)
        }
        _ = host.activate(from: NSRunningApplication.current)
        return (true, host.processIdentifier)
    }
#endif

    deinit {
        nativeMenuObservers.forEach { $0.remove() }
    }
}
