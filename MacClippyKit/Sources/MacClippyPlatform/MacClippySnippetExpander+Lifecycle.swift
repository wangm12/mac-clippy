import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

import MacClippyCore

extension MacClippySnippetExpander {
    public var isInstalled: Bool {
        withLifecycleLock { installed }
    }

    public var lastStartError: MacClippySnippetExpanderError? {
        withLifecycleLock { startError }
    }

    @discardableResult
    public func start() -> Bool {
        if Thread.isMainThread {
            return startOnMainThread()
        }
        return DispatchQueue.main.sync { [self] in startOnMainThread() }
    }

    private func startOnMainThread() -> Bool {
        if modeProvider() == .disabled {
            stopOnMainThread()
            withLifecycleLock { startError = nil }
            return true
        }
        if withLifecycleLock({ installed }) { return true }
        guard !withLifecycleLock({ stopCleanupPending }) else { return false }
        guard preflightPermissions(), let resources = createEventTap() else { return false }
        install(resources)
        focusContext.start { [weak self] in
            self?.focusContextDidChange()
        }
        return true
    }

    private func preflightPermissions() -> Bool {
        guard injector.canInjectAutomatically else {
            recordStartError(.accessibilityUnavailable)
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
            recordStartError(.inputMonitoringUnavailable)
            MacClippyLog.record(
                category: .permission,
                code: .permissionUnavailable,
                operation: "snippet_input_monitoring_preflight",
                recoveryAction: "open_accessibility_settings",
                impact: "snippet_expansion_unavailable"
            )
            return false
        }
        return true
    }

    private func createEventTap() -> (tap: CFMachPort, source: CFRunLoopSource)? {
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
            recordStartError(.eventTapUnavailable)
            MacClippyLog.record(
                category: .permission,
                code: .permissionUnavailable,
                operation: "snippet_event_tap_install",
                recoveryAction: "open_accessibility_settings",
                impact: "snippet_expansion_unavailable"
            )
            return nil
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            recordStartError(.runLoopSourceUnavailable)
            MacClippyLog.record(
                category: .hotkey,
                code: .hotkeyRegistrationFailed,
                operation: "snippet_event_tap_run_loop",
                recoveryAction: "retry_snippet_start",
                impact: "snippet_expansion_unavailable"
            )
            return nil
        }
        return (eventTap, source)
    }

    private func install(_ resources: (tap: CFMachPort, source: CFRunLoopSource)) {
        lifecycleLock.lock()
        if installed {
            lifecycleLock.unlock()
            CFMachPortInvalidate(resources.tap)
            return
        }
        if gateClosed {
            currentGate = MacClippyPasteInjectionGate()
            gateClosed = false
        }
        stopCleanupPending = false
        lifecycleGeneration &+= 1
        inputGeneration = 0
        planner.reset()
        plannerFocusIdentity = nil
        plannerFocusSelection = nil
        pendingRequest = nil
        let runLoop = CFRunLoopGetMain()
        CFRunLoopAddSource(runLoop, resources.source, .commonModes)
        CGEvent.tapEnable(tap: resources.tap, enable: true)
        eventTap = resources.tap
        runLoopSource = resources.source
        installed = true
        startError = nil
        lifecycleLock.unlock()
    }

    public func stop() {
        if Thread.isMainThread {
            stopOnMainThread()
            return
        }
        DispatchQueue.main.sync { [self] in stopOnMainThread() }
    }

    private func stopOnMainThread() {
        lifecycleLock.lock()
        currentGate.close()
        gateClosed = true
        lifecycleGeneration &+= 1
        inputGeneration &+= 1
        planner.reset()
        plannerFocusIdentity = nil
        plannerFocusSelection = nil
        pendingRequest = nil
        let deferTapCleanup = committingRequestIdentifier != nil || deferredInputReplayActive
        stopCleanupPending = deferTapCleanup
        let source = deferTapCleanup ? nil : runLoopSource
        let tap = deferTapCleanup ? nil : eventTap
        if !deferTapCleanup {
            runLoopSource = nil
            eventTap = nil
        }
        installed = false
        lifecycleLock.unlock()

        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        focusContext.stop()
    }

    package func finishDeferredStopIfNeeded() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.finishDeferredStopIfNeeded() }
            return
        }

        lifecycleLock.lock()
        guard stopCleanupPending,
              committingRequestIdentifier == nil,
              !deferredInputReplayActive else {
            lifecycleLock.unlock()
            return
        }
        stopCleanupPending = false
        let source = runLoopSource
        let tap = eventTap
        runLoopSource = nil
        eventTap = nil
        lifecycleLock.unlock()

        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }

    package func recordStartError(_ error: MacClippySnippetExpanderError) {
        withLifecycleLock { startError = error }
    }

    package func startForTesting() {
        lifecycleLock.lock()
        if gateClosed {
            currentGate = MacClippyPasteInjectionGate()
            gateClosed = false
        }
        lifecycleGeneration &+= 1
        inputGeneration = 0
        planner.reset()
        plannerFocusIdentity = nil
        plannerFocusSelection = nil
        pendingRequest = nil
        installed = true
        usesSyntheticInput = true
        lifecycleLock.unlock()
        focusContext.start { [weak self] in
            self?.focusContextDidChange()
        }
    }

    package func withLifecycleLock<T>(_ body: () -> T) -> T {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return body()
    }
}
