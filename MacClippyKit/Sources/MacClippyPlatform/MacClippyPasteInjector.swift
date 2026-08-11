import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum MacClippyPasteInjectionResult: Equatable, Sendable {
    case injected
    case manualPasteRequired
}

public typealias PasteInjectionResult = MacClippyPasteInjectionResult

public final class MacClippyPasteInjector {
    private struct PasteboardSnapshot {
        let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
        let isComplete: Bool
    }

    private let pasteboard: NSPasteboard
    private let isProcessTrusted: () -> Bool
    private let postEvents: (CGEvent, CGEvent) -> Void
    private let writeSentinel: MacClippyPasteboardWriteSentinel?
    private let prepareContent: (MacClippyPasteboardContent, NSPasteboard) -> Bool
    private let operationLock = NSLock()

    public init(
        pasteboard: NSPasteboard = .general,
        isProcessTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        postEvents: @escaping (CGEvent, CGEvent) -> Void = { keyDown, keyUp in
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        },
        writeSentinel: MacClippyPasteboardWriteSentinel? = nil,
        preparer: @escaping (MacClippyPasteboardContent, NSPasteboard) -> Bool = MacClippyPasteboardPreparer.prepare(_:on:)
    ) {
        self.pasteboard = pasteboard
        self.isProcessTrusted = isProcessTrusted
        self.postEvents = postEvents
        self.writeSentinel = writeSentinel
        self.prepareContent = preparer
    }

    /// Whether the process can post the keystrokes required for automatic
    /// paste. Snippet expansion uses this as a preflight so it never removes
    /// the user's trigger when Accessibility has been revoked.
    public var canInjectAutomatically: Bool {
        isProcessTrusted()
    }

    @discardableResult
    public func prepareText(
        _ text: String,
        gate: MacClippyPasteInjectionGate? = nil
    ) -> Bool {
        prepare(.text(text), gate: gate)
    }

    /// Writes text as a user-initiated copy so the pasteboard observer can
    /// record it in clipboard history. Automatic paste, snippet expansion,
    /// and regular in-app copy should continue using `prepareText`, which
    /// suppresses recapture through the write sentinel.
    @discardableResult
    public func prepareTextForHistory(
        _ text: String,
        gate: MacClippyPasteInjectionGate? = nil
    ) -> Bool {
        prepareForHistory(.text(text), gate: gate)
    }

    @discardableResult
    public func prepare(
        _ content: MacClippyPasteboardContent,
        gate: MacClippyPasteInjectionGate? = nil
    ) -> Bool {
        if let gate {
            return gate.withOpenGate {
                withOperationLock { prepareLocked(content, writeSentinel: writeSentinel) }
            } ?? false
        }
        return withOperationLock { prepareLocked(content, writeSentinel: writeSentinel) }
    }

    @discardableResult
    public func prepareForHistory(
        _ content: MacClippyPasteboardContent,
        gate: MacClippyPasteInjectionGate? = nil
    ) -> Bool {
        if let gate {
            return gate.withOpenGate {
                withOperationLock { prepareLocked(content, writeSentinel: nil) }
            } ?? false
        }
        return withOperationLock { prepareLocked(content, writeSentinel: nil) }
    }

    @discardableResult
    private func prepareLocked(
        _ content: MacClippyPasteboardContent,
        writeSentinel: MacClippyPasteboardWriteSentinel?
    ) -> Bool {
        let original = snapshotPasteboard()
        // A promised item may expose its UTI before its provider can
        // materialize bytes. Refuse to clear an incomplete snapshot because
        // there is no lossless way to restore that item after a failed copy.
        guard original.isComplete else { return false }

        guard prepareContentLocked(content, writeSentinel: writeSentinel) else {
            restore(original)
            return false
        }
        return true
    }

    private func prepareContentLocked(
        _ content: MacClippyPasteboardContent,
        writeSentinel: MacClippyPasteboardWriteSentinel?
    ) -> Bool {
        if let writeSentinel {
            return MacClippyPasteboardWriteCoordinator.write(
                content,
                on: pasteboard,
                sentinel: writeSentinel,
                preparer: prepareContent
            )
        }
        return prepareContent(content, pasteboard)
    }

    public func inject(
        text: String,
        beforePaste: (() -> Void)? = nil,
        gate: MacClippyPasteInjectionGate? = nil
    ) -> MacClippyPasteInjectionResult {
        inject(content: .text(text), beforePaste: beforePaste, gate: gate)
    }

    public func inject(
        content: MacClippyPasteboardContent,
        beforePaste: (() -> Void)? = nil,
        gate: MacClippyPasteInjectionGate? = nil
    ) -> MacClippyPasteInjectionResult {
        if let gate {
            return gate.withOpenGate {
                withOperationLock {
                    injectLocked(content: content, beforePaste: beforePaste)
                }
            } ?? .manualPasteRequired
        }
        return withOperationLock {
            injectLocked(content: content, beforePaste: beforePaste)
        }
    }

    private func withOperationLock<T>(_ operation: () -> T) -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return operation()
    }

    private func injectLocked(
        content: MacClippyPasteboardContent,
        beforePaste: (() -> Void)?
    ) -> MacClippyPasteInjectionResult {
        let original = snapshotPasteboard()
        // A promised pasteboard item can expose its UTI before its provider
        // can materialize bytes. Do not clear or replace an incomplete
        // snapshot: restoring it would silently drop the promised item.
        guard original.isComplete else { return .manualPasteRequired }
        let expectedInjectedChangeCount = pasteboard.changeCount + 1
        guard prepareContentLocked(content, writeSentinel: writeSentinel) else {
            writeSentinel?.cancel(changeCount: expectedInjectedChangeCount)
            restore(original)
            return .manualPasteRequired
        }

        guard isProcessTrusted() else {
            writeSentinel?.cancel(changeCount: expectedInjectedChangeCount)
            restore(original)
            return .manualPasteRequired
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            writeSentinel?.cancel(changeCount: expectedInjectedChangeCount)
            restore(original)
            return .manualPasteRequired
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // Callers such as Snippet expansion use this hook to remove the
        // trigger immediately before Cmd+V. All failure paths above return
        // before the hook, preserving the original user input.
        beforePaste?()
        postEvents(keyDown, keyUp)
        return .injected
    }

    private func snapshotPasteboard() -> PasteboardSnapshot {
        var isComplete = true
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> (type: NSPasteboard.PasteboardType, data: Data)? in
                guard let data = item.data(forType: type) else {
                    isComplete = false
                    return nil
                }
                return (type: type, data: data)
            }
        }
        return PasteboardSnapshot(items: items, isComplete: isComplete)
    }

    private func restore(_ snapshot: PasteboardSnapshot) {
        let expectedChangeCount = pasteboard.changeCount + 1
        writeSentinel?.beginWrite(expectedChangeCount: expectedChangeCount)
        pasteboard.clearContents()

        let restoredItems = snapshot.items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for value in values {
                _ = item.setData(value.data, forType: value.type)
            }
            return item
        }
        if !restoredItems.isEmpty, !pasteboard.writeObjects(restoredItems) {
            // The pasteboard was still cleared, so suppress that failed
            // restore generation rather than retaining a stale token.
            writeSentinel?.cancel(changeCount: expectedChangeCount)
        }
    }
}
