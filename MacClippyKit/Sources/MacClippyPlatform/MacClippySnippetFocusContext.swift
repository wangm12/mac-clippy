import AppKit
import ApplicationServices
import Foundation

/// Keeps AX work away from the event-tap callback. The serial sampler bounds
/// observation to five snapshots per second; the expander also asks for a new
/// snapshot at the final commit boundary.
/// Mutable monitor state is lock-protected across the AX, timer, and AppKit callback queues.
final class MacClippySnippetFocusContextMonitor: MacClippySnippetFocusContextSource, @unchecked Sendable {
    private let lock = NSLock()
    private let observationQueue = DispatchQueue(
        label: "com.macallyouneed.macclippy.snippet-focus-context",
        qos: .utility
    )
    private var identity: MacClippySnippetFocusIdentity?
    private var selection: MacClippySnippetTextSelection?
    private var changeHandler: (() -> Void)?
    private var workspaceObserver: NSObjectProtocol?
    private var axObserver: AXObserver?
    private var axRunLoopSource: CFRunLoopSource?
    private var observedApplication: AXUIElement?
    private var observedFocusedElement: AXUIElement?
    private var observedProcessIdentifier: pid_t?
    private var timer: DispatchSourceTimer?
    private var started = false
    private var lastInputTime = ProcessInfo.processInfo.systemUptime

    init(initialContext: MacClippySnippetFocusContext? = nil) {
        identity = initialContext?.identity
        selection = initialContext?.selection
    }

    private static let accessibilityCallback: AXObserverCallback = { _, _, notification, context in
        guard let context else { return }
        let monitor = Unmanaged<MacClippySnippetFocusContextMonitor>
            .fromOpaque(context)
            .takeUnretainedValue()
        monitor.accessibilityDidChange(notification)
    }

    var cachedIdentity: MacClippySnippetFocusIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return identity
    }

    var cachedSelection: MacClippySnippetTextSelection? {
        lock.lock()
        defer { lock.unlock() }
        return selection
    }

    func currentIdentity() -> MacClippySnippetFocusIdentity? {
        Self.readFrontmostFocusContext()?.identity
    }

    func currentContext() -> MacClippySnippetFocusContext? {
        Self.readFrontmostFocusContext()
    }

    func noteInputEvent() {
        lock.lock()
        lastInputTime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    func noteInputText(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !text.isEmpty else {
            // Editing/navigation keys have no text delta we can predict.
            // Wait for a fresh AX sample before using the caret as a trigger
            // anchor again.
            selection = nil
            return
        }
        guard let selection else { return }
        self.selection = MacClippySnippetTextSelection(
            location: selection.location + text.utf16.count,
            length: 0
        )
    }

    func start(onChange: @escaping () -> Void) {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        changeHandler = onChange
        lock.unlock()

        guard installWorkspaceActivationObserver() else { return }
        installIdentityRefreshTimer()
    }

    func stop() {
        lock.lock()
        started = false
        identity = nil
        selection = nil
        changeHandler = nil
        let timer = self.timer
        self.timer = nil
        let observer = workspaceObserver
        workspaceObserver = nil
        let axObserver = self.axObserver
        let axRunLoopSource = self.axRunLoopSource
        let applicationElement = observedApplication
        let focusedElement = observedFocusedElement
        self.axObserver = nil
        self.axRunLoopSource = nil
        observedApplication = nil
        observedFocusedElement = nil
        observedProcessIdentifier = nil
        lock.unlock()

        timer?.cancel()
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let axRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), axRunLoopSource, .commonModes)
        }
        if let axObserver, let applicationElement {
            AXObserverRemoveNotification(
                axObserver,
                applicationElement,
                kAXFocusedUIElementChangedNotification as CFString
            )
            if let focusedElement {
                AXObserverRemoveNotification(
                    axObserver,
                    focusedElement,
                    kAXSelectedTextChangedNotification as CFString
                )
            }
        }
    }

    func invalidateAndRefresh() {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        let didHaveIdentity = identity != nil
        identity = nil
        selection = nil
        let onChange = didHaveIdentity ? changeHandler : nil
        lock.unlock()

        onChange?()
        observationQueue.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            self?.refreshIdentity()
        }
    }
}

private extension MacClippySnippetFocusContextMonitor {
    func installWorkspaceActivationObserver() -> Bool {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let observer = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateAndRefresh()
        }
        lock.lock()
        guard started else {
            lock.unlock()
            notificationCenter.removeObserver(observer)
            return false
        }
        workspaceObserver = observer
        lock.unlock()
        return true
    }

    func installIdentityRefreshTimer() {
        let timer = DispatchSource.makeTimerSource(queue: observationQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(40))
        timer.setEventHandler { [weak self] in
            self?.refreshIdentity()
        }
        lock.lock()
        guard started else {
            lock.unlock()
            timer.resume()
            timer.cancel()
            return
        }
        self.timer = timer
        timer.resume()
        lock.unlock()
    }

    func refreshIdentity() {
        let sample = Self.readFrontmostAXElements()
        let nextContext = sample?.context
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        let didFocusChange = identity != nextContext?.identity
        let recentInput = ProcessInfo.processInfo.systemUptime - lastInputTime < 0.25
        let previousSelection = selection
        let sampledSelection = nextContext?.selection
        let staleCollapsedSelection = !didFocusChange
            && recentInput
            && previousSelection?.length == 0
            && sampledSelection?.length == 0
            && (sampledSelection?.location ?? Int.max) < (previousSelection?.location ?? Int.min)
        identity = nextContext?.identity
        if !staleCollapsedSelection {
            selection = sampledSelection
        }
        let didSelectionChange = !staleCollapsedSelection && previousSelection != sampledSelection
        let onChange = didFocusChange || didSelectionChange ? changeHandler : nil
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            if let sample {
                self?.updateAccessibilityObserver(for: sample)
            } else {
                self?.clearAccessibilityObserver()
            }
        }
        onChange?()
    }

    func accessibilityDidChange(_ notification: CFString) {
        if notification == kAXSelectedTextChangedNotification as CFString {
            lock.lock()
            let recentInput = ProcessInfo.processInfo.systemUptime - lastInputTime < 0.25
            lock.unlock()
            if recentInput {
                observationQueue.async { [weak self] in self?.refreshIdentity() }
                return
            }
        }
        invalidateAndRefresh()
    }

    func updateAccessibilityObserver(for sample: AXFocusSample) {
        guard Thread.isMainThread else { return }
        guard let oldState = detachAccessibilityObserverIfNeeded(for: sample) else { return }
        removeAccessibilityObserver(oldState)
        installAccessibilityObserver(for: sample)
    }

    func detachAccessibilityObserverIfNeeded(
        for sample: AXFocusSample
    ) -> AccessibilityObserverState? {
        lock.lock()
        guard started else {
            lock.unlock()
            return nil
        }
        if observedProcessIdentifier == sample.processIdentifier,
           axObserver != nil,
           let observedFocusedElement,
           CFHash(observedFocusedElement) == CFHash(sample.focusedElement) {
            lock.unlock()
            return nil
        }
        let oldState = AccessibilityObserverState(
            observer: axObserver,
            source: axRunLoopSource,
            applicationElement: observedApplication,
            focusedElement: observedFocusedElement
        )
        self.axObserver = nil
        axRunLoopSource = nil
        observedApplication = nil
        observedFocusedElement = nil
        observedProcessIdentifier = nil
        lock.unlock()
        return oldState
    }

    func removeAccessibilityObserver(_ state: AccessibilityObserverState) {
        if let source = state.source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let observer = state.observer, let applicationElement = state.applicationElement {
            AXObserverRemoveNotification(
                observer,
                applicationElement,
                kAXFocusedUIElementChangedNotification as CFString
            )
            if let focusedElement = state.focusedElement {
                AXObserverRemoveNotification(
                    observer,
                    focusedElement,
                    kAXSelectedTextChangedNotification as CFString
                )
            }
        }
    }

    func installAccessibilityObserver(for sample: AXFocusSample) {
        var createdObserver: AXObserver?
        guard AXObserverCreate(
            sample.processIdentifier,
            Self.accessibilityCallback,
            &createdObserver
        ) == .success,
        let createdObserver else { return }
        let contextPointer = Unmanaged.passUnretained(self).toOpaque()
        let applicationStatus = AXObserverAddNotification(
            createdObserver,
            sample.applicationElement,
            kAXFocusedUIElementChangedNotification as CFString,
            contextPointer
        )
        let selectionStatus = AXObserverAddNotification(
            createdObserver,
            sample.focusedElement,
            kAXSelectedTextChangedNotification as CFString,
            contextPointer
        )
        guard applicationStatus == .success || selectionStatus == .success else { return }
        let source = AXObserverGetRunLoopSource(createdObserver)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        lock.lock()
        guard started else {
            lock.unlock()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            return
        }
        axObserver = createdObserver
        axRunLoopSource = source
        observedApplication = sample.applicationElement
        observedFocusedElement = sample.focusedElement
        observedProcessIdentifier = sample.processIdentifier
        lock.unlock()
    }

    func clearAccessibilityObserver() {
        guard Thread.isMainThread else { return }
        lock.lock()
        let observer = axObserver
        let source = axRunLoopSource
        let applicationElement = observedApplication
        let focusedElement = observedFocusedElement
        axObserver = nil
        axRunLoopSource = nil
        observedApplication = nil
        observedFocusedElement = nil
        observedProcessIdentifier = nil
        lock.unlock()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let observer, let applicationElement {
            AXObserverRemoveNotification(
                observer,
                applicationElement,
                kAXFocusedUIElementChangedNotification as CFString
            )
            if let focusedElement {
                AXObserverRemoveNotification(
                    observer,
                    focusedElement,
                    kAXSelectedTextChangedNotification as CFString
                )
            }
        }
    }

    struct AccessibilityObserverState {
        let observer: AXObserver?
        let source: CFRunLoopSource?
        let applicationElement: AXUIElement?
        let focusedElement: AXUIElement?
    }

}
