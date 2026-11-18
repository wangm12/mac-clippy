import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MacClippyPlatform
import QuartzCore
import QuickLookUI
import SwiftUI

extension MacClippyDockController {
    func setSearchMode(_ isSearching: Bool) {
        if isSearching {
            if interactionMode != .search {
                enterSearchMode()
            }
        } else if interactionMode == .search {
            enterPickerMode()
        }
    }

    func routeKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard shouldRouteDockEvent(event) else { return event }
        // Keep the visible closing panel a keyboard sink until orderOut. This
        // prevents AppKit from forwarding the same key to an unrelated
        // responder during the short hide animation.
        if isClosing {
            return nil
        }
        let eventIdentity = ObjectIdentifier(event)
        if eventIdentity == lastRoutedEventIdentity {
            return nil
        }
        // The Preview panel is intentionally non-key so the Dock remains the
        // keyboard owner. Route image OCR selection directly before asking the
        // general picker policy for an action; otherwise a selected image can
        // lose ⌘C when AppKit has no native text responder.
        if routePreviewCommandCopy(event, eventIdentity: eventIdentity) {
            return nil
        }
        guard let keyEvent = dockKeyEvent(from: event) else { return event }
        noteSearchFieldClearKeys(event)
        if MacClippyDockInputMethodPolicy.shouldReapplySearchOverlayOnKeyEvent(),
           interactionMode == .search,
           event.type == .keyDown {
            applyOverlayLevel(allowsInputMethodCandidates: true)
        }
        let hasMarkedText = searchFieldHasMarkedText
        let action = keyAction(for: keyEvent, hasMarkedText: hasMarkedText)
        if routeNativeCommandCopy(event, action: action, eventIdentity: eventIdentity) {
            return nil
        }
        let consumed = applyKeyAction(action)
        if consumed {
            lastRoutedEventIdentity = eventIdentity
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastRoutedEventIdentity == eventIdentity else { return }
                self.lastRoutedEventIdentity = nil
            }
        }
        return consumed ? nil : event
    }

    private func shouldRouteDockEvent(_ event: NSEvent) -> Bool {
        panel?.isVisible == true && !snippetEditorWindow.owns(event: event)
            && !model.isFilterPopoverPresented && !model.isDetailsSaving && nativeMenuTrackingDepth == 0
    }

    private var hasFocusedActionTarget: Bool {
        switch interactionMode {
        case .details: details != nil && details?.id == detailsTargetID
        case .preview: previewTarget != nil
        default: model.focusedPreviewTarget != nil
        }
    }

    private func keyAction(for keyEvent: MacClippyDockKeyEvent, hasMarkedText: Bool) -> MacClippyDockKeyAction {
        if interactionMode == .details, details == nil,
           case let .keyDown(code, _, modifiers, isRepeat) = keyEvent,
           [36, 76].contains(code), modifiers.isDisjoint(with: [.command, .option, .control]) {
            return detailsIsLoading || isRepeat ? .consume : .retryDetails
        }
        return MacClippyDockKeyRouterPolicy.action(
            for: keyEvent,
            mode: interactionMode,
            hasCardFocus: hasFocusedActionTarget,
            hasMultipleSelection: model.hasMultipleSelection,
            detailsEditing: detailsEditing != .none,
            hasTextSelection: hasNativeTextSelection,
            isLoading: model.isLoading,
            alwaysPastePlainText: MacClippyRetentionPreferences.alwaysPastePlainText(from: model.defaults),
            letInputMethodOwnTyping: MacClippyDockInputMethodPolicy.letsInputMethodOwnTyping(
                hasMarkedText: hasMarkedText,
                inputSourceType: keyboardInputSourceType()
            ),
            hasMarkedText: hasMarkedText
        )
    }

    private func dockKeyEvent(from event: NSEvent) -> MacClippyDockKeyEvent? {
        switch event.type {
        case .keyDown:
            return .keyDown(
                keyCode: event.keyCode,
                characters: event.characters,
                modifiers: event.modifierFlags,
                isRepeat: event.isARepeat
            )
        case .keyUp:
            return .keyUp(keyCode: event.keyCode, modifiers: event.modifierFlags)
        default:
            return nil
        }
    }

    private func routeNativeCommandCopy(
        _ event: NSEvent,
        action: MacClippyDockKeyAction,
        eventIdentity: ObjectIdentifier
    ) -> Bool {
        guard action == .native,
              event.type == .keyDown,
              MacClippyDockKeyRouterPolicy.isCommandCopy(
                  keyCode: event.keyCode,
                  modifiers: event.modifierFlags
              ) else { return false }
        if let selectionHost = selectedPreviewSelectionHost,
           selectionHost.hasSelectedText {
            selectionHost.copySelectedText()
            lastRoutedEventIdentity = eventIdentity
            return true
        }
        guard let previewTextView = selectedPreviewTextView else { return false }
        previewTextView.copy(nil)
        lastRoutedEventIdentity = eventIdentity
        return true
    }

    private func routePreviewCommandCopy(
        _ event: NSEvent,
        eventIdentity: ObjectIdentifier
    ) -> Bool {
        guard interactionMode == .preview,
              event.type == .keyDown,
              MacClippyDockKeyRouterPolicy.isCommandCopy(
                  keyCode: event.keyCode,
                  modifiers: event.modifierFlags
              ),
              let selectionHost = selectedPreviewSelectionHost,
              selectionHost.hasSelectedText else {
            return false
        }
        selectionHost.copySelectedText()
        lastRoutedEventIdentity = eventIdentity
        return true
    }

    private func noteSearchFieldClearKeys(_ event: NSEvent) {
        guard event.type == .keyDown else { return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isDeleteKey = event.keyCode == 51 || event.keyCode == 117
        let isCommandA = event.keyCode == 0 && modifiers == [.command]
        guard MacClippyDockSearchQueryWritePolicy.notesSearchFieldUserEdit(
            isSearchMode: interactionMode == .search,
            isDeleteKey: isDeleteKey,
            isCommandA: isCommandA
        ) else { return }
        model.noteSearchFieldUserKeyEvent()
    }

    func focusSearchFieldEditor() {
        guard let contentView = panel?.contentView,
              let field = firstTextField(in: contentView) else { return }
        if panel?.firstResponder === field
            || (field.currentEditor() != nil && panel?.firstResponder === field.currentEditor()) {
            return
        }
        panel?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            panel?.makeFirstResponder(editor)
        }
    }

    var searchFieldHasMarkedText: Bool {
        markedTextClient?.hasMarkedText() == true
    }

    private var markedTextClient: NSTextInputClient? {
        let fieldEditor = panel?.contentView.flatMap { firstTextField(in: $0) }?.currentEditor()
        let responders: [NSResponder?] = [
            NSApp.keyWindow?.firstResponder,
            panel?.firstResponder,
            (panel?.firstResponder as? NSTextField)?.currentEditor(),
            (NSApp.keyWindow?.firstResponder as? NSTextField)?.currentEditor(),
            fieldEditor
        ]
        for responder in responders {
            if let client = responder as? NSTextInputClient {
                return client
            }
        }
        return nil
    }

    func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable {
            return field
        }
        for subview in view.subviews {
            if let field = firstTextField(in: subview) {
                return field
            }
        }
        return nil
    }

    private var hasNativeTextSelection: Bool {
        if let selectionHost = selectedPreviewSelectionHost,
           selectionHost.hasSelectedText {
            return true
        }
        let responder = NSApp.keyWindow?.firstResponder
        if let textView = responder as? NSTextView {
            return textView.selectedRange.length > 0
        }
        if let textField = responder as? NSTextField {
            return textField.currentEditor()?.selectedRange.length ?? 0 > 0
        }
        return selectedPreviewTextView != nil
    }

    private var selectedPreviewSelectionHost: MacClippyPreviewTextSelectionHost? {
        guard previewPanel?.isVisible == true,
              let contentView = previewPanel?.contentView else { return nil }
        return firstSelectionHost(in: contentView)
    }

    private var selectedPreviewTextView: NSTextView? {
        guard previewPanel?.isVisible == true,
              let contentView = previewPanel?.contentView else { return nil }
        return firstSelectedTextView(in: contentView)
    }

    private func firstSelectedTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.selectedRange.length > 0 {
            return textView
        }
        for subview in view.subviews {
            if let selected = firstSelectedTextView(in: subview) {
                return selected
            }
        }
        return nil
    }

    private func firstSelectionHost(in view: NSView) -> MacClippyPreviewTextSelectionHost? {
        if let host = view as? MacClippyPreviewTextSelectionHost,
           host.hasSelectedText {
            return host
        }
        for subview in view.subviews {
            if let host = firstSelectionHost(in: subview) {
                return host
            }
        }
        return nil
    }

    func consumePanelKey(_ event: NSEvent) -> Bool {
        routeKeyEvent(event) == nil
    }
}
