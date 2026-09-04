import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum MacClippyPasteInjectionResult: Equatable, Sendable {
    case injected
    case manualPasteRequired
}

public typealias PasteInjectionResult = MacClippyPasteInjectionResult

extension Notification.Name {
    public static let macClippyWillInjectPasteKeystroke = Notification.Name(
        "com.macallyouneed.macclippy.willInjectPasteKeystroke"
    )
    public static let macClippyDidInjectPasteKeystroke = Notification.Name(
        "com.macallyouneed.macclippy.didInjectPasteKeystroke"
    )
}

public final class MacClippyPasteInjector {
    private struct PasteboardSnapshot {
        let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
        let isComplete: Bool
        let changeCount: Int
    }

    private let pasteboard: NSPasteboard
    private let isProcessTrusted: () -> Bool
    private let postEvents: (CGEvent, CGEvent) -> Void
    private let writeSentinel: MacClippyPasteboardWriteSentinel?
    private let prepareContent: (MacClippyPasteboardContent, NSPasteboard) -> Bool
    private let writeObjects: (NSPasteboard, [NSPasteboardWriting]) -> Bool
    private let operationLock = NSLock()

    public init(
        pasteboard: NSPasteboard = .general,
        isProcessTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        postEvents: @escaping (CGEvent, CGEvent) -> Void = { keyDown, keyUp in
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        },
        writeSentinel: MacClippyPasteboardWriteSentinel? = nil,
        preparer: @escaping (MacClippyPasteboardContent, NSPasteboard) -> Bool = {
            MacClippyPasteboardPreparer.prepare($0, on: $1)
        },
        writeObjects: ((NSPasteboard, [NSPasteboardWriting]) -> Bool)? = nil
    ) {
        self.pasteboard = pasteboard
        self.isProcessTrusted = isProcessTrusted
        self.postEvents = postEvents
        self.writeSentinel = writeSentinel
        self.prepareContent = preparer
        self.writeObjects = writeObjects ?? { pasteboard, items in
            pasteboard.writeObjects(items)
        }
    }

    /// Whether the process can post the keystrokes required for automatic
    /// paste. Snippet expansion uses this as a preflight so it never removes
    /// the user's trigger when Accessibility has been revoked.
    public var canInjectAutomatically: Bool {
        isProcessTrusted()
    }

    public func currentPlainText() -> String? {
        pasteboard.string(forType: .string)
    }

    public func prepareText(
        _ text: String,
        gate: MacClippyPasteInjectionGate? = nil
    ) throws {
        try prepare(.text(text), gate: gate)
    }

    /// Writes text as a user-initiated copy so the pasteboard observer can
    /// record it in clipboard history. Automatic paste, snippet expansion,
    /// and regular in-app copy should continue using `prepareText`, which
    /// suppresses recapture through the write sentinel.
    public func prepareTextForHistory(
        _ text: String,
        gate: MacClippyPasteInjectionGate? = nil
    ) throws {
        try prepareForHistory(.text(text), gate: gate)
    }

    public func prepare(
        _ content: MacClippyPasteboardContent,
        gate: MacClippyPasteInjectionGate? = nil
    ) throws {
        try withOptionalGate(gate) {
            try withOperationLock { try prepareLocked(content, writeSentinel: writeSentinel) }
        }
    }

    public func prepareForHistory(
        _ content: MacClippyPasteboardContent,
        gate: MacClippyPasteInjectionGate? = nil
    ) throws {
        try withOptionalGate(gate) {
            try withOperationLock { try prepareLocked(content, writeSentinel: nil) }
        }
    }

    private func prepareLocked(
        _ content: MacClippyPasteboardContent,
        writeSentinel: MacClippyPasteboardWriteSentinel?
    ) throws {
        let original = snapshotPasteboard()
        // A promised item may expose its UTI before its provider can
        // materialize bytes. Refuse to clear an incomplete snapshot because
        // there is no lossless way to restore that item after a failed copy.
        guard original.isComplete else {
            throw MacClippyPasteboardPrepareError.incompleteSnapshot
        }

        guard prepareContentLocked(content, writeSentinel: writeSentinel) else {
            if restore(original) {
                throw MacClippyPasteboardPrepareError.writeFailed
            }
            throw MacClippyPasteboardPrepareError.restoreFailed
        }
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

    private func withOptionalGate(
        _ gate: MacClippyPasteInjectionGate?,
        _ operation: () throws -> Void
    ) throws {
        guard let gate else {
            try operation()
            return
        }
        var captured: Result<Void, Error>?
        let opened = gate.withOpenGate {
            captured = Result { try operation() }
        }
        guard opened != nil, let captured else {
            throw MacClippyPasteboardPrepareError.gateClosed
        }
        try captured.get()
    }

    private func withOperationLock<T>(_ operation: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try operation()
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
            _ = restore(original)
            return .manualPasteRequired
        }

        guard isProcessTrusted() else {
            writeSentinel?.cancel(changeCount: expectedInjectedChangeCount)
            _ = restore(original)
            return .manualPasteRequired
        }

        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            writeSentinel?.cancel(changeCount: expectedInjectedChangeCount)
            _ = restore(original)
            return .manualPasteRequired
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // Callers such as Snippet expansion use this hook to remove the
        // trigger immediately before Cmd+V. All failure paths above return
        // before the hook, preserving the original user input.
        beforePaste?()
        postPasteKeystrokeNotification(.macClippyWillInjectPasteKeystroke)
        postEvents(keyDown, keyUp)
        postPasteKeystrokeNotification(.macClippyDidInjectPasteKeystroke)
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
        return PasteboardSnapshot(
            items: items,
            isComplete: isComplete,
            changeCount: pasteboard.changeCount
        )
    }

    /// Restores a snapshot after a failed prepare/inject. Clears once, then
    /// retries `writeObjects` without clearing again. Aborts if another writer
    /// changed the pasteboard after that clear.
    @discardableResult
    private func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        let expectedPreparedChangeCount = snapshot.changeCount + 1
        guard pasteboard.changeCount <= expectedPreparedChangeCount else {
            return false
        }

        let restoredItems = snapshot.items.map { values -> NSPasteboardWriting in
            let item = NSPasteboardItem()
            for value in values {
                _ = item.setData(value.data, forType: value.type)
            }
            return item
        }

        let expectedAfterClear = pasteboard.changeCount + 1
        writeSentinel?.beginWrite(expectedChangeCount: expectedAfterClear)
        pasteboard.clearContents()
        guard pasteboard.changeCount == expectedAfterClear else {
            writeSentinel?.cancel(changeCount: expectedAfterClear)
            return false
        }
        if restoredItems.isEmpty {
            return true
        }
        if writeObjects(pasteboard, restoredItems) {
            return true
        }
        guard pasteboard.changeCount == expectedAfterClear else {
            writeSentinel?.cancel(changeCount: expectedAfterClear)
            return false
        }
        // The retry writes into the generation the clear above already opened.
        // `writeObjects` does not bump changeCount, so registering a second
        // token here would stamp the *next* foreign copy instead.
        if writeObjects(pasteboard, restoredItems) {
            return true
        }
        writeSentinel?.cancel(changeCount: expectedAfterClear)
        return false
    }

    private func postPasteKeystrokeNotification(_ name: Notification.Name) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: name, object: self)
        } else {
            DispatchQueue.main.sync {
                NotificationCenter.default.post(name: name, object: self)
            }
        }
    }
}
