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
// SAFETY: Every read/write of the lookup map is protected by `lock`.
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
        defer { lock.unlock() }
        bodiesByTrigger.removeValue(forKey: trigger)
    }
}

package struct MacClippySnippetSyntheticKeyInput: Sendable {
    package let text: String
    package let keyCode: UInt16
    package let hasDisqualifyingModifiers: Bool

    package init(text: String, keyCode: UInt16 = 0, hasDisqualifyingModifiers: Bool = false) {
        self.text = text
        self.keyCode = keyCode
        self.hasDisqualifyingModifiers = hasDisqualifyingModifiers
    }
}

// AppKit/CGEvent resources are owned by the main-thread lifecycle boundary.
// The state lock protects planner and generation values; it is never held
// across AX reads or injector calls.
public final class MacClippySnippetExpander: @unchecked Sendable {
    public typealias Lookup = (String) -> String?

    package struct ExpansionRequest {
        let identifier: UInt64
        let plan: MacClippySnippetExpansionPlan
        let focusIdentity: MacClippySnippetFocusIdentity
        let expectedSelection: MacClippySnippetTextSelection?
        let lifecycleGeneration: UInt64
        let inputGeneration: UInt64
        let gate: MacClippyPasteInjectionGate
    }

    package let modeProvider: () -> MacClippySnippetExpansionMode
    package let injector: MacClippyPasteInjector
    package let keyPoster: MacClippySnippetKeyPoster
    package let focusContext: MacClippySnippetFocusContextSource
    package let clipboardTextProvider: () -> String?
    package let expansionDidFinish: () -> Void
    package let expansionQueue = DispatchQueue(
        label: "com.macallyouneed.macclippy.snippet-expansion",
        qos: .userInitiated
    )
    package let deferredInputReplayQueue = DispatchQueue(
        label: "com.macallyouneed.macclippy.snippet-input-replay",
        qos: .userInteractive
    )
    package let lifecycleLock = NSLock()
    package let commitLock = NSLock()
    package var planner: MacClippySnippetExpansionPlanner
    package var eventTap: CFMachPort?
    package var runLoopSource: CFRunLoopSource?
    package var installed = false
    package var startError: MacClippySnippetExpanderError?
    package var lifecycleGeneration: UInt64 = 0
    package var inputGeneration: UInt64 = 0
    package var nextRequestIdentifier: UInt64 = 0
    package var plannerFocusIdentity: MacClippySnippetFocusIdentity?
    package var plannerFocusSelection: MacClippySnippetTextSelection?
    package var pendingRequest: ExpansionRequest?
    package var deferredInputReplayItems: [MacClippySnippetDeferredInputItem] = []
    package var deferredInputReplayActive = false
    package var deferredInputReplayScheduled = false
    package var committingRequestIdentifier: UInt64?
    package var committingProcessIdentifier: Int32?
    package var stopCleanupPending = false
    package var currentGate = MacClippyPasteInjectionGate()
    package var gateClosed = false
    package var usesSyntheticInput = false

    public convenience init(
        modeProvider: @escaping () -> MacClippySnippetExpansionMode = { MacClippySnippetExpansionSettings.load() },
        lookup: @escaping Lookup,
        injector: MacClippyPasteInjector = MacClippyPasteInjector(),
        keyPoster: MacClippySnippetKeyPoster = MacClippySnippetKeyPoster()
    ) {
        self.init(
            modeProvider: modeProvider,
            lookup: lookup,
            injector: injector,
            keyPoster: keyPoster,
            focusContext: MacClippySnippetFocusContextMonitor(),
            clipboardTextProvider: { injector.currentPlainText() },
            expansionDidFinish: {}
        )
    }

    package init(
        modeProvider: @escaping () -> MacClippySnippetExpansionMode,
        lookup: @escaping Lookup,
        injector: MacClippyPasteInjector,
        keyPoster: MacClippySnippetKeyPoster,
        focusContext: MacClippySnippetFocusContextSource,
        clipboardTextProvider: @escaping () -> String?,
        expansionDidFinish: @escaping () -> Void = {}
    ) {
        self.modeProvider = modeProvider
        self.injector = injector
        self.keyPoster = keyPoster
        self.focusContext = focusContext
        self.clipboardTextProvider = clipboardTextProvider
        self.expansionDidFinish = expansionDidFinish
        planner = MacClippySnippetExpansionPlanner(
            modeProvider: modeProvider,
            lookup: lookup
        )
    }

    deinit {
        stop()
    }

}
