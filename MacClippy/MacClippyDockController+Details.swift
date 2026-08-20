import AppKit
import SwiftUI

@MainActor
extension MacClippyDockController {
    func showDetails() {
        guard let dockPanel = panel, dockPanel.isVisible,
              let target = model.focusedItem else { return }
        dismissPreviewImmediately()
        interactionMode = .details
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
        setDetailsRootView(AnyView(MacClippyDetailsLoadingView()))
        let targetID = target.id
        detailsRequestID &+= 1
        let requestID = detailsRequestID
        model.loadDetails(for: targetID) { [weak self, weak panel] result in
            guard let self, let panel,
                  self.detailsRequestID == requestID,
                  self.interactionMode == .details,
                  self.model.focusedItem?.id == targetID else { return }
            switch result {
            case let .success(details):
                self.details = details
                self.setDetailsRootView(AnyView(self.detailsView(details: details, editing: .none)))
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
        guard detailsEditing != .none else { return true }
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
        detailsPanel?.orderOut(nil)
        detailsPanel?.close()
        detailsPanel = nil
        detailsHostingView = nil
    }

    func beginDetailsEditing(_ editing: MacClippyDetailsEditing) {
        guard interactionMode == .details, let details else { return }
        guard editing == .name || details.isEditable else { return }
        guard editing != .content
            || (details.textContent?.count ?? 0) <= MacClippyDockPreviewTextPolicy.maxRenderedCharacters else {
            model.setErrorForDetails("Content too large to edit inline — use Copy instead")
            return
        }
        detailsEditing = editing
        detailsHostingView?.rootView = AnyView(detailsView(details: details, editing: editing))
        detailsPanel?.makeKey()
    }

    func cancelDetailsEditing() {
        guard let details else { return }
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
            onEditingChanged: { [weak self] isEditing in self?.detailsEditing = isEditing ? editing : .none },
            onEdit: { [weak self] in self?.beginDetailsEditing(.content) },
            onRename: { [weak self] in self?.beginDetailsEditing(.name) },
            onSaveContent: { [weak self] text in self?.saveDetailsContent(text) },
            onSaveName: { [weak self] name in self?.saveDetailsName(name) },
            onCancelEdit: { [weak self] in self?.cancelDetailsEditing() },
            onPreview: { [weak self] in self?.showPreview() },
            onCopy: { [weak self] in self?.model.copyFocused() },
            onPlainCopy: details.contentKind == .text || details.contentKind == .html || details.contentKind == .rtf
                ? { [weak self] in self?.model.copyFocused(plain: true) } : nil,
            onTransformCopy: details.isEditable
                ? { [weak self] transform in self?.model.copyFocused(transform: transform) } : nil,
            onTransformPaste: details.isEditable
                ? { [weak self] transform in
                    self?.model.pasteFocused(transform: transform, completion: { self?.hide() })
                } : nil,
            onPaste: { [weak self] in self?.model.pasteFocused(completion: { self?.hide() }) },
            onPin: { [weak self] in
                self?.model.togglePinFocused { [weak self] in self?.refreshDetails() }
            },
            onDelete: { [weak self] in
                guard let self, self.hideDetails() else { return }
                self.model.deleteFocused()
            },
            onClose: { [weak self] in self?.hideDetails() }
        )
    }

    func saveDetailsContent(_ text: String) {
        guard let details else { return }
        let targetID = details.id
        let requestID = detailsRequestID
        guard text.count <= MacClippyDockPreviewTextPolicy.maxRenderedCharacters else {
            // Keep the editor open so the user can shorten the draft. The
            // original-content check above only protects the initial view and
            // does not cover replacing it with a larger draft.
            model.setErrorForDetails("Content too large to edit inline — use Copy instead")
            return
        }
        model.editDetails(id: details.id, text: text) { [weak self] result in
            guard let self else { return }
            guard self.detailsRequestID == requestID,
                  self.interactionMode == .details,
                  self.details?.id == targetID else { return }
            switch result {
            case .success:
                self.detailsEditing = .none
                self.showDetails()
            case let .failure(error):
                self.model.setErrorForDetails(
                    MacClippyUserFacingError.message(for: error, fallback: MacClippyUserFacingError.itemSave)
                )
            }
        }
    }

    func saveDetailsName(_ name: String) {
        guard let details else { return }
        let targetID = details.id
        let requestID = detailsRequestID
        model.renameDetails(id: details.id, name: name) { [weak self] result in
            guard let self else { return }
            guard self.detailsRequestID == requestID,
                  self.interactionMode == .details,
                  self.details?.id == targetID else { return }
            switch result {
            case .success:
                self.detailsEditing = .none
                self.showDetails()
            case let .failure(error):
                self.model.setErrorForDetails(
                    MacClippyUserFacingError.message(for: error, fallback: MacClippyUserFacingError.itemSave)
                )
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
