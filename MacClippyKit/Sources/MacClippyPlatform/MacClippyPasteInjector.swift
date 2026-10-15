import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Describes whether a paste event was posted or content was only prepared.
/// `injected` means the keystroke events were delivered; it does not confirm
/// that the target application accepted or inserted the clipboard contents.
public enum MacClippyPasteInjectionResult: Equatable, Sendable {
    case injected
    case preparedForManualPaste
    case failed(MacClippyPasteInjectionFailure)
    case cancelled
}

public enum MacClippyPasteInjectionFailure: Error, Equatable, Sendable, LocalizedError {
    case accessibilityUnavailable
    case incompleteClipboard
    case clipboardChanged
    case preparationFailed
    case pasteboardWriteFailed
    case clipboardRestoreFailed
    case eventCreationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityUnavailable:
            return "Enable Accessibility access to paste this snippet automatically."
        case .incompleteClipboard:
            return "The current clipboard contains data that cannot be safely restored."
        case .clipboardChanged:
            return "The clipboard changed before the paste could be prepared. Try again."
        case .preparationFailed:
            return "The selected content could not be prepared for paste."
        case .pasteboardWriteFailed:
            return "The selected content could not be written to the clipboard."
        case .clipboardRestoreFailed:
            return "The clipboard could not be restored after a failed paste."
        case .eventCreationFailed:
            return "The paste keystroke could not be created."
        }
    }
}

public enum MacClippyPasteManualFallbackPolicy: Equatable, Sendable {
    /// Leave the selected content on the clipboard when event posting is not
    /// available so the user can paste it manually.
    case prepareClipboard
    /// Preserve the existing clipboard and never synthesize a manual fallback.
    /// Used by snippet expansion, which must keep its typed trigger intact.
    case preserveClipboard
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

public final class MacClippyPasteInjector: @unchecked Sendable {
    struct PasteboardSnapshot {
        let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
        let isComplete: Bool
        let changeCount: Int
    }

    struct PasteEvents {
        let keyDown: CGEvent
        let keyUp: CGEvent
    }

    struct InjectionRequest {
        let beforePaste: (() -> Bool)?
        let afterPasteEvents: (() -> Void)?
        let validateBeforePaste: (() -> Bool)?
        let validateCommitContext: (() -> Bool)?
        let manualFallback: MacClippyPasteManualFallbackPolicy
        let gate: MacClippyPasteInjectionGate?
        let targetProcessIdentifier: Int32?
    }

    enum SnapshotWriteResult {
        case written(changeCount: Int)
        case failed(restoreIfChangeCountIs: Int?)
        case cancelled(restoreIfChangeCountIs: Int?)
        case clipboardChanged
        case restoreFailed
    }

    let pasteboard: NSPasteboard
    let pasteboardAccessCoordinator: MacClippyPasteboardAccessCoordinator
    let isProcessTrusted: () -> Bool
    let postEvents: (CGEvent, CGEvent) -> Void
    let postEventsToProcess: ((CGEvent, CGEvent, Int32) -> Void)?
    let writeSentinel: MacClippyPasteboardWriteSentinel?
    let prepareContent: (MacClippyPasteboardContent, NSPasteboard) -> Bool
    let writeObjects: (NSPasteboard, [NSPasteboardWriting]) -> Bool
    let operationLock = NSLock()
    var preEventAdmissionHookForTesting: (() -> Void)?

    public init(
        pasteboard: NSPasteboard = .general,
        isProcessTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        postEvents: @escaping (CGEvent, CGEvent) -> Void = { keyDown, keyUp in
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        },
        postEventsToProcess: ((CGEvent, CGEvent, Int32) -> Void)? = nil,
        writeSentinel: MacClippyPasteboardWriteSentinel? = nil,
        pasteboardAccessCoordinator: MacClippyPasteboardAccessCoordinator? = nil,
        preparer: @escaping (MacClippyPasteboardContent, NSPasteboard) -> Bool = {
            MacClippyPasteboardPreparer.prepare($0, on: $1)
        },
        writeObjects: ((NSPasteboard, [NSPasteboardWriting]) -> Bool)? = nil
    ) {
        self.pasteboard = pasteboard
        self.pasteboardAccessCoordinator = pasteboardAccessCoordinator ?? .shared(for: pasteboard)
        self.isProcessTrusted = isProcessTrusted
        self.postEvents = postEvents
        self.postEventsToProcess = postEventsToProcess
        self.writeSentinel = writeSentinel
        self.prepareContent = preparer
        self.writeObjects = writeObjects ?? { pasteboard, items in
            (try? MacClippyNativePasteboard.write(items, to: pasteboard)) ?? false
        }
        self.preEventAdmissionHookForTesting = nil
    }

    @_spi(Testing)
    public func setPreEventAdmissionHookForTesting(_ hook: (() -> Void)?) {
        withOperationLock {
            preEventAdmissionHookForTesting = hook
        }
    }

    /// Whether the process can post the keystrokes required for automatic
    /// paste. Snippet expansion uses this as a preflight so it never removes
    /// the user's trigger when Accessibility has been revoked.
    public var canInjectAutomatically: Bool {
        isProcessTrusted()
    }

    public func currentPlainText() -> String? {
        pasteboardAccessCoordinator.withAccess {
            try? MacClippyNativePasteboard.string(from: pasteboard, forType: .string)
        }
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
        try prepare(content, gate: gate, sentinel: writeSentinel)
    }

    public func prepareForHistory(
        _ content: MacClippyPasteboardContent,
        gate: MacClippyPasteInjectionGate? = nil
    ) throws {
        try prepare(content, gate: gate, sentinel: nil)
    }

    public func inject(
        text: String,
        beforePaste: (() -> Bool)? = nil,
        afterPasteEvents: (() -> Void)? = nil,
        validateBeforePaste: (() -> Bool)? = nil,
        validateCommitContext: (() -> Bool)? = nil,
        manualFallback: MacClippyPasteManualFallbackPolicy = .prepareClipboard,
        gate: MacClippyPasteInjectionGate? = nil,
        targetProcessIdentifier: Int32? = nil
    ) -> MacClippyPasteInjectionResult {
        inject(
            content: .text(text),
            beforePaste: beforePaste,
            afterPasteEvents: afterPasteEvents,
            validateBeforePaste: validateBeforePaste,
            validateCommitContext: validateCommitContext,
            manualFallback: manualFallback,
            gate: gate,
            targetProcessIdentifier: targetProcessIdentifier
        )
    }

    /// Runs synchronously after this request's paste events return. It also
    /// runs when cancellation closes the gate after event posting was admitted,
    /// and is not called when the request is canceled before posting.
    public func inject(
        content: MacClippyPasteboardContent,
        beforePaste: (() -> Bool)? = nil,
        afterPasteEvents: (() -> Void)? = nil,
        validateBeforePaste: (() -> Bool)? = nil,
        validateCommitContext: (() -> Bool)? = nil,
        manualFallback: MacClippyPasteManualFallbackPolicy = .prepareClipboard,
        gate: MacClippyPasteInjectionGate? = nil,
        targetProcessIdentifier: Int32? = nil
    ) -> MacClippyPasteInjectionResult {
        let request = InjectionRequest(
            beforePaste: beforePaste,
            afterPasteEvents: afterPasteEvents,
            validateBeforePaste: validateBeforePaste,
            validateCommitContext: validateCommitContext,
            manualFallback: manualFallback,
            gate: gate,
            targetProcessIdentifier: targetProcessIdentifier
        )
        return withOperationLock {
            injectLocked(content: content, request: request)
        }
    }

    func withOperationLock<T>(_ operation: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try operation()
    }
}
