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

    public init(
        pasteboard: NSPasteboard = .general,
        isProcessTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        postEvents: @escaping (CGEvent, CGEvent) -> Void = { keyDown, keyUp in
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        },
        writeSentinel: MacClippyPasteboardWriteSentinel? = nil
    ) {
        self.pasteboard = pasteboard
        self.isProcessTrusted = isProcessTrusted
        self.postEvents = postEvents
        self.writeSentinel = writeSentinel
    }

    @discardableResult
    public func prepareText(_ text: String) -> Bool {
        prepare(.text(text))
    }

    @discardableResult
    public func prepare(_ content: MacClippyPasteboardContent) -> Bool {
        if let writeSentinel {
            return MacClippyPasteboardWriteCoordinator.write(
                content,
                on: pasteboard,
                sentinel: writeSentinel
            )
        }
        return MacClippyPasteboardPreparer.prepare(content, on: pasteboard)
    }

    public func inject(text: String) -> MacClippyPasteInjectionResult {
        inject(content: .text(text))
    }

    public func inject(content: MacClippyPasteboardContent) -> MacClippyPasteInjectionResult {
        let original = snapshotPasteboard()
        // A promised pasteboard item can expose its UTI before its provider
        // can materialize bytes. Do not clear or replace an incomplete
        // snapshot: restoring it would silently drop the promised item.
        guard original.isComplete else { return .manualPasteRequired }
        let expectedInjectedChangeCount = pasteboard.changeCount + 1
        guard prepare(content) else {
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
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            writeSentinel?.cancel(changeCount: expectedInjectedChangeCount)
            restore(original)
            return .manualPasteRequired
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
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
