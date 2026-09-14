import AppKit
import SwiftUI

import MacClippyPlatform

/// AppKit owns IME composition. SwiftUI only receives text after the native
/// window field editor has committed it.
struct MacClippyAppKitSearchField: NSViewRepresentable {
    var committedQuery: String
    var isFocused: Bool
    var collapseToken: Int
    var programmaticSyncToken: Int
    var onCommit: (String) -> Void
    var onFocusChange: (Bool) -> Void
    var onCompositionChange: (Bool) -> Void
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MacClippyIMESearchField {
        let field = MacClippyIMESearchField()
        field.delegate = context.coordinator
        context.coordinator.attach(to: field, parent: self)
        return field
    }

    func updateNSView(_ field: MacClippyIMESearchField, context: Context) {
        context.coordinator.attach(to: field, parent: self)
        field.applyChrome()
        let composing = context.coordinator.publishComposition(from: field)
        let isEditing = field.isEditing
        let programmaticSync =
            programmaticSyncToken != context.coordinator.lastProgrammaticSyncToken
            || (collapseToken > 0 && collapseToken != context.coordinator.lastCollapseToken)
        context.coordinator.lastProgrammaticSyncToken = programmaticSyncToken
        if collapseToken > 0 {
            context.coordinator.lastCollapseToken = collapseToken
        }
        if MacClippyDockSearchQueryWritePolicy.shouldApplyExternalStringToFieldEditor(
            hasMarkedText: composing,
            incoming: committedQuery,
            current: field.stringValue,
            isEditing: isEditing,
            programmaticSync: programmaticSync
        ) {
            field.stringValue = committedQuery
        }
        if programmaticSync,
           MacClippyDockSearchQueryWritePolicy.shouldApplyProgrammaticCaret(hasMarkedText: composing) {
            let caret = MacClippyDockSearchQueryWritePolicy.caretAfterProgrammaticFocus(
                query: field.stringValue
            )
            field.currentEditor()?.selectedRange = MacClippyDockSearchQueryWritePolicy.selectedRange(
                caret: caret,
                queryUTF16Length: (field.stringValue as NSString).length
            )
        }
        if MacClippyDockSearchQueryWritePolicy.shouldMakeSearchFieldFirstResponder(
            wantsFocus: isFocused,
            isAlreadyEditing: isEditing,
            hasMarkedText: composing
        ) {
            field.window?.makeFirstResponder(field)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacClippyAppKitSearchField?
        var lastCollapseToken = 0
        var lastProgrammaticSyncToken = 0
        private var lastComposing: Bool?

        func attach(to field: MacClippyIMESearchField, parent: MacClippyAppKitSearchField) {
            self.parent = parent
            field.coordinator = self
        }

        func publishComposition(from field: NSTextField) -> Bool {
            let marked = (field.currentEditor() as? NSTextInputClient)?.hasMarkedText() ?? false
            publishCompositionFlag(marked)
            return marked
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let composing = publishComposition(from: field)
            guard MacClippyDockSearchQueryWritePolicy.shouldPublishFieldEditorString(
                hasMarkedText: composing
            ) else { return }
            parent?.onCommit(field.stringValue)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent?.onFocusChange(true)
            if let field = notification.object as? NSTextField {
                _ = publishComposition(from: field)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent?.onFocusChange(false)
            if let field = notification.object as? NSTextField {
                _ = publishComposition(from: field)
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent?.onSubmit()
                return true
            }
            return false
        }

        private func publishCompositionFlag(_ composing: Bool) {
            if lastComposing != composing {
                lastComposing = composing
                parent?.onCompositionChange(composing)
            }
        }
    }
}

@MainActor
final class MacClippyIMESearchField: NSTextField {
    weak var coordinator: MacClippyAppKitSearchField.Coordinator?

    var isEditing: Bool {
        if currentEditor() != nil { return true }
        if window?.firstResponder === self { return true }
        return false
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.usesSingleLineMode = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyChrome()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fieldEditorDidChangeSelection(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func fieldEditorDidChangeSelection(_ notification: Notification) {
        guard let text = notification.object as? NSText,
              let editor = currentEditor(),
              text === editor else { return }
        _ = coordinator?.publishComposition(from: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyChrome() {
        font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        textColor = MacClippyDockTheme.text
        let placeholder = NSAttributedString(
            string: "Search clipboard...",
            attributes: [
                .foregroundColor: MacClippyDockTheme.muted2,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            ]
        )
        placeholderAttributedString = placeholder
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyChrome()
    }
}
