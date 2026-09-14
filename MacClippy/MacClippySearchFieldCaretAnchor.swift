import AppKit
import SwiftUI

import MacClippyPlatform

/// SwiftUI's `TextField` selects all on programmatic focus. Picker-mode
/// typing focuses after the first character is already in `query`, so the
/// next key replaces that character. This walks to the AppKit field editor
/// and collapses the selection to an insertion point.
struct MacClippySearchFieldCaretAnchor: NSViewRepresentable {
    var query: String
    var collapseToken: Int
    var onCompositionChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MacClippySearchFieldCaretHostView {
        let view = MacClippySearchFieldCaretHostView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MacClippySearchFieldCaretHostView, context: Context) {
        let coordinator = context.coordinator
        let queryChanged = coordinator.query != query
        let tokenChanged = coordinator.collapseToken != collapseToken
        coordinator.query = query
        coordinator.collapseToken = collapseToken
        coordinator.onCompositionChange = onCompositionChange
        nsView.coordinator = coordinator
        guard MacClippyDockSearchQueryWritePolicy.shouldRefreshCaretHost(
            queryChanged: queryChanged,
            collapseTokenChanged: tokenChanged
        ) else { return }
        coordinator.noteHierarchyReady(from: nsView)
    }

    @MainActor
    static func apply(caret: MacClippyDockSearchFieldCaret, from view: NSView? = nil) {
        Coordinator.apply(caret: caret, from: view)
    }

    @MainActor
    final class Coordinator {
        var query = ""
        var collapseToken = 0
        var onCompositionChange: ((Bool) -> Void)?
        private var lastBurstToken = 0
        private var collapseDeadline: Date?
        private var lastReportedComposing: Bool?

        func noteHierarchyReady(from view: NSView) {
            guard collapseToken > 0 else { return }
            let caret = MacClippyDockSearchQueryWritePolicy.caretAfterProgrammaticFocus(query: query)
            if lastBurstToken != collapseToken {
                lastBurstToken = collapseToken
                collapseDeadline = Date().addingTimeInterval(0.45)
                Self.scheduleApply(
                    caret: caret,
                    from: view,
                    remaining: MacClippyDockSearchQueryWritePolicy.caretCollapseApplyCount
                )
                return
            }
            guard isCollapseWindowOpen else { return }
            Self.apply(caret: caret, from: view)
        }

        func collapseIfTokenActive(from view: NSView) {
            publishCompositionState(from: view)
            guard isCollapseWindowOpen else { return }
            Self.apply(
                caret: MacClippyDockSearchQueryWritePolicy.caretAfterProgrammaticFocus(query: query),
                from: view
            )
        }

        func publishCompositionState(from view: NSView) {
            let composing = Self.hasMarkedText(from: view)
            guard lastReportedComposing != composing else { return }
            lastReportedComposing = composing
            onCompositionChange?(composing)
        }

        private static func hasMarkedText(from view: NSView) -> Bool {
            if let client = view.window?.firstResponder as? NSTextInputClient {
                return client.hasMarkedText()
            }
            if let field = nearbyTextField(from: view),
               let client = field.currentEditor() as? NSTextInputClient {
                return client.hasMarkedText()
            }
            return false
        }

        private var isCollapseWindowOpen: Bool {
            collapseToken > 0 && (collapseDeadline.map { Date() < $0 } ?? false)
        }

        static func apply(caret: MacClippyDockSearchFieldCaret, from view: NSView? = nil) {
            if let view, apply(caret, from: view) {
                return
            }
            guard let key = NSApp.keyWindow else { return }
            if apply(caret, to: key.firstResponder) {
                return
            }
            if let contentView = key.contentView,
               let field = firstTextField(in: contentView, remainingDepth: 6) {
                _ = apply(caret, to: field)
            }
        }

        private static func scheduleApply(
            caret: MacClippyDockSearchFieldCaret,
            from view: NSView,
            remaining: Int
        ) {
            apply(caret: caret, from: view)
            guard remaining > 1 else { return }
            Task { @MainActor in
                scheduleApply(caret: caret, from: view, remaining: remaining - 1)
            }
        }

        private static func apply(_ caret: MacClippyDockSearchFieldCaret, from view: NSView) -> Bool {
            if let window = view.window, apply(caret, to: window.firstResponder) {
                return true
            }
            if let field = nearbyTextField(from: view) {
                return apply(caret, to: field)
            }
            return false
        }

        private static func apply(_ caret: MacClippyDockSearchFieldCaret, to responder: NSResponder?) -> Bool {
            if let text = responder as? NSText {
                apply(caret, to: text)
                return true
            }
            if let field = responder as? NSTextField {
                return apply(caret, to: field)
            }
            return false
        }

        private static func apply(_ caret: MacClippyDockSearchFieldCaret, to field: NSTextField) -> Bool {
            if let editor = field.currentEditor() {
                apply(caret, to: editor)
                return true
            }
            return false
        }

        private static func apply(_ caret: MacClippyDockSearchFieldCaret, to text: NSText) {
            let hasMarkedText = (text as? NSTextInputClient)?.hasMarkedText() ?? false
            guard MacClippyDockSearchQueryWritePolicy.shouldApplyProgrammaticCaret(
                hasMarkedText: hasMarkedText
            ) else { return }
            let utf16Length = (text.string as NSString).length
            text.selectedRange = MacClippyDockSearchQueryWritePolicy.selectedRange(
                caret: caret,
                queryUTF16Length: utf16Length
            )
        }

        private static func nearbyTextField(from view: NSView) -> NSTextField? {
            var current: NSView? = view
            var depth = 0
            while let node = current, depth < 6 {
                if let field = node as? NSTextField {
                    return field
                }
                if let parent = node.superview {
                    for sibling in parent.subviews {
                        if let field = firstTextField(in: sibling, remainingDepth: 3) {
                            return field
                        }
                    }
                }
                current = node.superview
                depth += 1
            }
            return nil
        }

        private static func firstTextField(in view: NSView, remainingDepth: Int) -> NSTextField? {
            if let field = view as? NSTextField {
                return field
            }
            guard remainingDepth > 0 else { return nil }
            for child in view.subviews {
                if let field = firstTextField(in: child, remainingDepth: remainingDepth - 1) {
                    return field
                }
            }
            return nil
        }
    }
}

@MainActor
final class MacClippySearchFieldCaretHostView: NSView {
    weak var coordinator: MacClippySearchFieldCaretAnchor.Coordinator?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        observeFieldEditor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func observeFieldEditor() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fieldEditorDidChangeSelection(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fieldEditorDidChange(_:)),
            name: NSText.didChangeNotification,
            object: nil
        )
    }

    @objc private func fieldEditorDidChangeSelection(_ notification: Notification) {
        guard isFieldEditor(in: notification) else { return }
        coordinator?.publishCompositionState(from: self)
        guard
            let text = notification.object as? NSText,
            MacClippyDockSearchQueryWritePolicy.shouldCollapseFullSelection(
                selectedUTF16Length: text.selectedRange.length,
                queryUTF16Length: (text.string as NSString).length,
                hasMarkedText: (text as? NSTextInputClient)?.hasMarkedText() ?? false
            )
        else { return }
        collapseFromFieldEditor()
    }

    @objc private func fieldEditorDidChange(_ notification: Notification) {
        guard isFieldEditor(in: notification) else { return }
        coordinator?.publishCompositionState(from: self)
    }

    private func isFieldEditor(in notification: Notification) -> Bool {
        guard let text = notification.object as? NSText else { return window == nil }
        return window == nil || text.window === window
    }

    private func collapseFromFieldEditor() {
        coordinator?.collapseIfTokenActive(from: self)
    }
}
