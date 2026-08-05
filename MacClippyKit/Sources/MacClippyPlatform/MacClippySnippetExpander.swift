import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

import MacClippyCore

public enum MacClippySnippetExpanderError: Error, Equatable, Sendable {
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
}

public final class MacClippySnippetExpander {
    public typealias Lookup = (String) -> String?

    private static let eventsOfInterest: CGEventMask = 1 << CGEventType.keyDown.rawValue

    private let modeProvider: () -> MacClippySnippetExpansionMode
    private let injector: MacClippyPasteInjector
    private var planner: MacClippySnippetExpansionPlanner
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public private(set) var isInstalled = false
    public private(set) var lastStartError: MacClippySnippetExpanderError?

    public init(
        modeProvider: @escaping () -> MacClippySnippetExpansionMode = { MacClippySnippetExpansionSettings.load() },
        lookup: @escaping Lookup,
        injector: MacClippyPasteInjector = MacClippyPasteInjector()
    ) {
        self.modeProvider = modeProvider
        self.injector = injector
        planner = MacClippySnippetExpansionPlanner(modeProvider: modeProvider, lookup: lookup)
    }

    @discardableResult
    public func start() -> Bool {
        guard !isInstalled else { return true }

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
            lastStartError = .eventTapUnavailable
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
            lastStartError = .runLoopSourceUnavailable
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
        isInstalled = true
        lastStartError = nil
        return true
    }

    public func stop() {
        planner.reset()
        guard isInstalled else { return }

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        isInstalled = false
    }

    deinit {
        stop()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
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

            DispatchQueue.main.async { [weak self] in
                self?.expand(using: plan)
            }
            return plan.suppressCurrentEvent ? nil : Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func expand(using plan: MacClippySnippetExpansionPlan) {
        for _ in 0 ..< plan.charactersToDelete {
            postKey(UInt16(kVK_Delete))
        }
        _ = injector.inject(text: plan.body)
    }

    private func postKey(_ keyCode: UInt16) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)?.post(tap: .cgAnnotatedSessionEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
