import AppKit
import SwiftUI
import MacClippyCore

@MainActor
extension MacClippyDockController {
    func showCardDetails(id: RecordID, editing: Bool) {
        showDetails(editing: editing ? .content : .none, targetID: id)
    }

    func showDetails(editing requestedEditing: MacClippyDetailsEditing = .none, targetID requestedID: RecordID? = nil) {
        guard let dockPanel = panel, dockPanel.isVisible,
              let targetID = requestedID ?? model.focusedItem?.id,
              confirmDetailsDismissalIfNeeded() else { return }
        detailsTargetID = targetID
        dismissPreviewImmediately()
        interactionMode = .details
        model.resetSearchFocus()
        detailsEditing = .none
        let frame = detailsFrame(for: dockPanel)
        let panel: MacClippyDetailsPanel
        if let existing = detailsPanel {
            panel = existing
        } else {
            panel = MacClippyDetailsPanel(contentRect: frame)
            detailsPanel = panel
        }
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        details = nil
        detailsEditSession = nil
        detailsIsLoading = true
        setDetailsRootView(AnyView(MacClippyDetailsLoadingView()))
        detailsRequestID &+= 1
        let requestID = detailsRequestID
        model.loadDetails(for: targetID) { [weak self, weak panel] result in
            guard let self, let panel,
                  self.detailsRequestID == requestID,
                  self.interactionMode == .details,
                  self.detailsTargetID == targetID else { return }
            self.detailsIsLoading = false
            switch result {
            case let .success(details):
                self.details = details
                self.detailsEditSession = MacClippyDetailsEditSession(details: details)
                self.setDetailsRootView(AnyView(self.detailsView(details: details, editing: .none)))
                if requestedEditing != .none { self.beginDetailsEditing(requestedEditing) }
                panel.makeKey()
            case let .failure(error):
                self.details = nil
                self.setDetailsRootView(AnyView(MacClippyDetailsErrorView(
                    message: MacClippyUserFacingError.message(for: error, fallback: MacClippyUserFacingError.itemLoad),
                    onRetry: { [weak self] in self?.refreshDetails() },
                    onClose: { [weak self] in self?.hideDetails() }
                )))
            }
        }
    }

    func setDetailsRootView(_ rootView: AnyView) {
        guard let panel = detailsPanel else { return }
        if let detailsHostingView {
            detailsHostingView.rootView = rootView
        } else {
            let hostingView = NSHostingView(rootView: rootView)
            self.detailsHostingView = hostingView
            panel.contentView = hostingView
        }
    }

    @discardableResult
    func hideDetails() -> Bool {
        guard confirmDetailsDismissalIfNeeded() else { return false }
        detailsRequestID &+= 1
        detailsEditing = .none
        details = nil
        detailsIsLoading = false
        detailsEditSession = nil
        model.isDetailsSaving = false
        detailsTargetID = nil
        if interactionMode == .details {
            interactionMode = .picker
            model.resetSearchFocus()
        }
        detailsPanel?.orderOut(nil)
        detailsHostingView = nil
        panel?.interceptsPickerKeys = isVisible
        if let dockPanel = panel, dockPanel.isVisible {
            takeKeyboardOwnership(of: dockPanel)
        }
        return true
    }

    private func confirmDetailsDismissalIfNeeded() -> Bool {
        guard detailsEditSession?.isSaving != true else { return false }
        guard detailsEditSession?.isDirty(editing: detailsEditing) == true else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Your clipboard edits have not been saved."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func dismissDetailsImmediately() {
        detailsRequestID &+= 1
        detailsEditing = .none
        details = nil
        detailsIsLoading = false
        detailsEditSession = nil
        model.isDetailsSaving = false
        detailsTargetID = nil
        detailsPanel?.orderOut(nil)
        detailsPanel?.close()
        detailsPanel = nil
        detailsHostingView = nil
    }

    func beginDetailsEditing(_ editing: MacClippyDetailsEditing) {
        guard interactionMode == .details, let details, confirmDetailsDismissalIfNeeded() else { return }
        guard editing == .name || details.isEditable else { return }
        guard editing != .content
            || (details.textContent?.count ?? 0) <= MacClippyDockPreviewTextPolicy.maxRenderedCharacters else {
            detailsEditSession?.errorMessage = "Content too large to edit inline — use Copy instead"
            return
        }
        if editing != detailsEditing { detailsEditSession?.resetDrafts() }
        detailsEditing = editing
        detailsHostingView?.rootView = AnyView(detailsView(details: details, editing: editing))
        detailsPanel?.makeKey()
    }

    func cancelDetailsEditing() {
        guard let details, confirmDetailsDismissalIfNeeded() else { return }
        detailsEditSession?.resetDrafts()
        detailsEditing = .none
        detailsHostingView?.rootView = AnyView(detailsView(details: details, editing: .none))
        detailsPanel?.makeKey()
    }

    func detailsView(
        details: MacClippyItemDetails,
        editing: MacClippyDetailsEditing
    ) -> MacClippyDetailsView {
        MacClippyDetailsView(
            details: details,
            editing: editing,
            editSession: detailsEditSession,
            onEdit: { [weak self] in self?.beginDetailsEditing(.content) },
            onRename: { [weak self] in self?.beginDetailsEditing(.name) },
            onSaveContent: { [weak self] text, intent in self?.saveDetailsContent(text, intent: intent) },
            onSaveName: { [weak self] name, intent in self?.saveDetailsName(name, intent: intent) },
            onCancelEdit: { [weak self] in self?.cancelDetailsEditing() },
            onPreview: { [weak self] in self?.showPreview(for: .item(details.id)) },
            onCopy: { [weak self] in self?.model.copyRecord(id: details.id) },
            onPlainCopy: details.contentKind == .text || details.contentKind == .html || details.contentKind == .rtf
                ? { [weak self] in self?.model.copyRecord(id: details.id, plain: true) } : nil,
            onTransformCopy: details.isEditable
                ? { [weak self] transform in self?.model.copyRecord(id: details.id, transform: transform) } : nil,
            onTransformPaste: details.isEditable
                ? { [weak self] transform in
                    self?.model.pasteRecord(id: details.id, transform: transform, completion: { self?.hide() })
                } : nil,
            onPaste: { [weak self] in self?.model.selectRecord(id: details.id, completion: { self?.hide() }) },
            onPin: { [weak self] in
                guard let self, self.hideDetails() else { return }
                self.model.requestPinSelection(ids: [details.id])
            },
            onDelete: { [weak self] in
                guard let self, self.hideDetails() else { return }
                self.model.requestDeleteRecords(ids: [details.id])
            },
            onClose: { [weak self] in self?.hideDetails() }
        )
    }

    func saveDetailsContent(_ text: String, intent: MacClippyDetailsSaveIntent = .save) {
        guard let details, let editor = detailsEditSession, !editor.isSaving else { return }
        guard text.count <= MacClippyDockPreviewTextPolicy.maxRenderedCharacters else {
            editor.errorMessage = "Content too large to edit inline — use Copy instead"
            return
        }
        editor.contentDraft = text
        beginDetailsSave(editor)
        let requestID = detailsRequestID
        model.editDetails(id: details.id, text: text) { [weak self] result in
            self?.completeDetailsSave(result, editor: editor, requestID: requestID, intent: intent)
        }
    }

    func saveDetailsName(_ name: String, intent: MacClippyDetailsSaveIntent = .save) {
        guard let details, let editor = detailsEditSession, !editor.isSaving else { return }
        editor.nameDraft = name
        beginDetailsSave(editor)
        let requestID = detailsRequestID
        model.renameDetails(id: details.id, name: name) { [weak self] result in
            self?.completeDetailsSave(result, editor: editor, requestID: requestID, intent: intent)
        }
    }

    private func beginDetailsSave(_ editor: MacClippyDetailsEditSession) {
        editor.errorMessage = nil
        editor.isSaving = true
        model.isDetailsSaving = true
    }

    private func completeDetailsSave(
        _ result: Result<Void, Error>, editor: MacClippyDetailsEditSession,
        requestID: UInt, intent: MacClippyDetailsSaveIntent
    ) {
        guard detailsRequestID == requestID, interactionMode == .details,
              detailsTargetID == editor.recordID, detailsEditSession === editor else { return }
        switch result {
        case .success:
            editor.markSaved()
            refreshSavedDetails(editor: editor, intent: intent)
        case let .failure(error):
            editor.isSaving = false
            model.isDetailsSaving = false
            editor.errorMessage = MacClippyUserFacingError.message(
                for: error, fallback: MacClippyUserFacingError.itemSave
            )
        }
    }

    private func refreshSavedDetails(editor: MacClippyDetailsEditSession, intent: MacClippyDetailsSaveIntent) {
        let id = editor.recordID
        detailsRequestID += 1
        let requestID = detailsRequestID
        model.loadDetails(for: id) { [weak self] result in
            guard let self, self.detailsRequestID == requestID,
                  self.detailsTargetID == id, self.interactionMode == .details,
                  self.detailsEditSession === editor else { return }
            switch result {
            case let .success(details):
                self.details = details
                self.detailsEditSession = MacClippyDetailsEditSession(details: details)
                self.detailsEditing = .none
                self.model.isDetailsSaving = false
                self.setDetailsRootView(AnyView(self.detailsView(details: details, editing: .none)))
                if intent == .saveAndPaste {
                    self.model.selectRecord(id: id, completion: { [weak self] in self?.hide() })
                }
            case let .failure(error):
                editor.isSaving = false
                self.model.isDetailsSaving = false
                self.detailsEditSession?.errorMessage = MacClippyUserFacingError.message(for: error)
            }
        }
    }

    func detailsFrame(for dockPanel: NSWindow) -> NSRect {
        let screen = screen(for: dockPanel) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? dockPanel.frame
        let inset: CGFloat = 12
        let size = NSSize(
            width: min(600, max(1, visible.width - inset * 2)),
            height: min(680, max(1, visible.height - inset * 2))
        )
        var frame = NSRect(
            x: dockPanel.frame.maxX - size.width,
            y: dockPanel.frame.maxY + 12,
            width: size.width,
            height: size.height
        )
        if frame.maxY > visible.maxY { frame.origin.y = dockPanel.frame.minY - size.height - 12 }
        if frame.minX < visible.minX { frame.origin.x = visible.minX + 12 }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - size.width - 12 }
        if frame.minY < visible.minY { frame.origin.y = visible.minY + inset }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - size.height - inset }
        return frame
    }
}
