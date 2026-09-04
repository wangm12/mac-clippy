import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

import MacClippyCore

public enum MacClippySnippetExpanderError: Error, Equatable, Sendable {
    case accessibilityUnavailable
    case inputMonitoringUnavailable
    case eventTapUnavailable
    case runLoopSourceUnavailable
}

// Event-tap callbacks must never wait on a database read or decrypt a
// snippet. Runtime refreshes this snapshot when the snippet list is loaded or
// changed; lookups during typing are a short, lock-protected memory read.
// SAFETY: The only mutable state is `bodiesByTrigger`, and every read/write
// is protected by `lock`. The synchronous API is intentional because the
// event-tap callback cannot await an actor without changing event handling.
public final class MacClippySnippetLookupSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var bodiesByTrigger: [String: String] = [:]

    public init() {}

    public func replace(with snippets: [Snippet]) {
        var next: [String: String] = [:]
        next.reserveCapacity(snippets.count)
        for snippet in snippets {
            guard let trigger = snippet.trigger?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trigger.isEmpty else { continue }
            next[trigger] = snippet.body
        }

        lock.lock()
        bodiesByTrigger = next
        lock.unlock()
    }

    public func body(for trigger: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return bodiesByTrigger[trigger]
    }

    public func remove(trigger: String?) {
        guard let trigger, !trigger.isEmpty else { return }
        lock.lock()
        bodiesByTrigger.removeValue(forKey: trigger)
        lock.unlock()
    }
}

// AppKit/CGEvent resources are owned by the main-thread lifecycle boundary;
// the lifecycle lock protects the small state read by the event-tap callback.
public final class MacClippySnippetExpander: @unchecked Sendable {
    public typealias Lookup = (String) -> String?

    private static let eventsOfInterest: CGEventMask = 1 << CGEventType.keyDown.rawValue

    private let modeProvider: () -> MacClippySnippetExpansionMode
    private let injector: MacClippyPasteInjector
    private let keyPoster: MacClippySnippetKeyPoster
    private let lifecycleLock = NSLock()
    private var planner: MacClippySnippetExpansionPlanner
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var installed = false
    private var startError: MacClippySnippetExpanderError?
    // Invalidates expansion plans that were queued by the event-tap callback
    // but have not reached the main queue yet.
    private var lifecycleGeneration: UInt64 = 0

    public var isInstalled: Bool {
        withLifecycleLock { installed }
    }

    public var lastStartError: MacClippySnippetExpanderError? {
        withLifecycleLock { startError }
    }

    public init(
        modeProvider: @escaping () -> MacClippySnippetExpansionMode = { MacClippySnippetExpansionSettings.load() },
        lookup: @escaping Lookup,
        injector: MacClippyPasteInjector = MacClippyPasteInjector(),
        keyPoster: MacClippySnippetKeyPoster = MacClippySnippetKeyPoster()
    ) {
        self.modeProvider = modeProvider
        self.injector = injector
        self.keyPoster = keyPoster
        planner = MacClippySnippetExpansionPlanner(modeProvider: modeProvider, lookup: lookup)
    }

    @discardableResult
    public func start() -> Bool {
        // Event taps and their CFRunLoop sources are AppKit lifecycle
        // resources. Runtime normally calls this from the main actor, but the
        // public platform API is also used by tests and permission refreshes;
        // make the executor boundary explicit instead of relying on callers.
        if Thread.isMainThread {
            return startOnMainThread()
        }
        return DispatchQueue.main.sync { [self] in
            startOnMainThread()
        }
    }

    private func startOnMainThread() -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        // Re-read the mode while holding the same lock used by install and
        // uninstall. This closes the preference-change window where a stale
        // enabled check could install an event tap after the user disabled
        // Snippets.
        if modeProvider() == .disabled {
            stopLocked()
            startError = nil
            return true
        }
        guard !installed else { return true }

        guard injector.canInjectAutomatically else {
            startError = .accessibilityUnavailable
            MacClippyLog.record(
                category: .permission,
                code: .permissionUnavailable,
                operation: "snippet_accessibility_preflight",
                recoveryAction: "open_accessibility_settings",
                impact: "snippet_expansion_unavailable"
            )
            return false
        }

        guard CGPreflightListenEventAccess() else {
            startError = .inputMonitoringUnavailable
            MacClippyLog.record(
                category: .permission,
                code: .permissionUnavailable,
                operation: "snippet_input_monitoring_preflight",
                recoveryAction: "open_input_monitoring_settings",
                impact: "snippet_expansion_unavailable"
            )
            return false
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let expander = Unmanaged<MacClippySnippetExpander>.fromOpaque(userInfo).takeUnretainedValue()
            return expander.handle(type: type, event: event)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventsOfInterest,
            callback: callback,
            userInfo: context
        ) else {
            startError = .eventTapUnavailable
            MacClippyLog.record(
                category: .permission,
                code: .permissionUnavailable,
                operation: "snippet_event_tap_install",
                recoveryAction: "open_accessibility_settings",
                impact: "snippet_expansion_unavailable"
            )
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            startError = .runLoopSourceUnavailable
            MacClippyLog.record(
                category: .hotkey,
                code: .hotkeyRegistrationFailed,
                operation: "snippet_event_tap_run_loop",
                recoveryAction: "retry_snippet_start",
                impact: "snippet_expansion_unavailable"
            )
            return false
        }

        let runLoop = CFRunLoopGetMain()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        self.eventTap = eventTap
        runLoopSource = source
        installed = true
        startError = nil
        return true
    }

    public func stop() {
        if Thread.isMainThread {
            stopOnMainThread()
            return
        }
        DispatchQueue.main.sync { [self] in
            stopOnMainThread()
        }
    }

    private func stopOnMainThread() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        lifecycleGeneration &+= 1
        planner.reset()
        guard installed else { return }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        installed = false
    }

    deinit {
        stop()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return nil
        }

        var actualLength = 0
        var characters = [UniChar](repeating: 0, count: 64)
        event.keyboardGetUnicodeString(
            maxStringLength: characters.count,
            actualStringLength: &actualLength,
            unicodeString: &characters
        )
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let rawString = String(characters.prefix(actualLength).compactMap { Unicode.Scalar($0).map(Character.init) })
        let typedString = rawString.isEmpty && keyCode == UInt16(kVK_Tab) ? "\t" : rawString
        guard !typedString.isEmpty else { return Unmanaged.passUnretained(event) }
        let generation = lifecycleGeneration

        let flags = event.flags
        let hasDisqualifyingModifiers = flags.contains(.maskCommand)
            || flags.contains(.maskControl)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskShift)

        for character in typedString {
            guard let plan = planner.handle(
                character,
                keyCode: keyCode,
                hasDisqualifyingModifiers: hasDisqualifyingModifiers
            ) else { continue }

            // Do not suppress the delimiter if Accessibility disappeared
            // after the event tap was installed. The trigger remains visible
            // and the user can still paste it manually.
            guard injector.canInjectAutomatically else {
                return Unmanaged.passUnretained(event)
            }

            DispatchQueue.main.async { [weak self] in
                self?.expand(using: plan, generation: generation)
            }
            return plan.suppressCurrentEvent ? nil : Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func withLifecycleLock<T>(_ body: () -> T) -> T {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return body()
    }

    private func expand(using plan: MacClippySnippetExpansionPlan, generation: UInt64) {
        let canExpand = withLifecycleLock {
            lifecycleGeneration == generation
                && installed
                && modeProvider() != .disabled
        }
        guard canExpand else { return }
        let body = MacClippySnippetVariablePolicy.expand(
            plan.body,
            context: MacClippySnippetVariableContext(clipboard: injector.currentPlainText())
        )
        let result = injector.inject(text: body) { [weak self] in
            guard let self else { return }
            for _ in 0 ..< plan.charactersToDelete {
                postKey(UInt16(kVK_Delete))
            }
        }
        guard result == .manualPasteRequired else { return }
        restoreSuppressedDelimiter(for: plan)
    }

    package func expandForTesting(using plan: MacClippySnippetExpansionPlan) {
        let generation = withLifecycleLock {
            installed = true
            return lifecycleGeneration
        }
        expand(using: plan, generation: generation)
    }

    // Expansion output must not re-enter the session tap that detects
    // triggers, so these keys never use the injector's paste event path.
    private func postKey(_ keyCode: UInt16) {
        keyPoster.post(keyCode: keyCode)
    }

    private func restoreSuppressedDelimiter(for plan: MacClippySnippetExpansionPlan) {
        guard let keyCode = plan.suppressedDelimiterKeyCode else { return }
        postKey(keyCode)
    }
}
