import AppKit
import SwiftUI
import MacClippyCore

enum MacClippyDetailsEditing: Equatable {
    case none
    case content
    case name
}

enum MacClippyDetailsFocusedField: Hashable {
    case content
    case name
}

struct MacClippyDetailsView: View {
    let details: MacClippyItemDetails
    let editing: MacClippyDetailsEditing
    let onEditingChanged: (Bool) -> Void
    let onEdit: () -> Void
    let onRename: () -> Void
    let onSaveContent: (String) -> Void
    let onSaveName: (String) -> Void
    let onCancelEdit: () -> Void
    let onPreview: () -> Void
    let onCopy: () -> Void
    let onPlainCopy: (() -> Void)?
    let onTransformCopy: ((TextTransform) -> Void)?
    let onTransformPaste: ((TextTransform) -> Void)?
    let onPaste: () -> Void
    let onPin: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State var contentDraft: String
    @State var nameDraft: String
    @FocusState var focusedField: MacClippyDetailsFocusedField?

    init(
        details: MacClippyItemDetails,
        editing: MacClippyDetailsEditing = .none,
        onEditingChanged: @escaping (Bool) -> Void = { _ in },
        onEdit: @escaping () -> Void = {},
        onRename: @escaping () -> Void = {},
        onSaveContent: @escaping (String) -> Void = { _ in },
        onSaveName: @escaping (String) -> Void = { _ in },
        onCancelEdit: @escaping () -> Void = {},
        onPreview: @escaping () -> Void = {},
        onCopy: @escaping () -> Void = {},
        onPlainCopy: (() -> Void)? = nil,
        onTransformCopy: ((TextTransform) -> Void)? = nil,
        onTransformPaste: ((TextTransform) -> Void)? = nil,
        onPaste: @escaping () -> Void = {},
        onPin: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.details = details
        self.editing = editing
        self.onEditingChanged = onEditingChanged
        self.onEdit = onEdit
        self.onRename = onRename
        self.onSaveContent = onSaveContent
        self.onSaveName = onSaveName
        self.onCancelEdit = onCancelEdit
        self.onPreview = onPreview
        self.onCopy = onCopy
        self.onPlainCopy = onPlainCopy
        self.onTransformCopy = onTransformCopy
        self.onTransformPaste = onTransformPaste
        self.onPaste = onPaste
        self.onPin = onPin
        self.onDelete = onDelete
        self.onClose = onClose
        _contentDraft = State(initialValue: details.textContent ?? "")
        _nameDraft = State(initialValue: details.customLabel ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .macClippyFloatingGlass(in: Rectangle())
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    contentSection
                    metadataSection
                    representationsSection
                }
                .padding(22)
            }
            .background(MacClippyDockTheme.cardColor)
            Divider()
            footer
                .macClippyFloatingGlass(in: Rectangle())
        }
        .frame(minWidth: 320, minHeight: 360)
        .background(MacClippyDockTheme.cardColor)
        .onAppear { onEditingChanged(editing != .none) }
        .onChange(of: editing) { _, value in
            onEditingChanged(value != .none)
            resetDrafts(for: value)
            focusField(for: value)
        }
        .onChange(of: details.id) { _, _ in
            resetDrafts(for: editing)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(MacClippyDockTheme.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(details.title.isEmpty ? "Untitled item" : details.title)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityLabel(
                        details.customLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                            ? (details.customLabel ?? "Named clipboard item")
                            : "Clipboard \(details.contentKind.rawValue) item"
                    )
                Text(details.contentKind.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Preview", action: onPreview)
                .buttonStyle(.bordered)
            Button { onClose() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Close details")
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var contentSection: some View {
        section("Content") {
            if editing == .content && canEditContent {
                TextEditor(text: $contentDraft)
                    .font(.body)
                    .frame(minHeight: 180)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .focused($focusedField, equals: .content)
                    .accessibilityLabel("Clipboard content")
                    .accessibilityHint("Edit the saved clipboard content")
                    HStack {
                        Button("Cancel", action: onCancelEdit)
                        Spacer()
                        Button("Save") { onSaveContent(contentDraft) }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text(contentDisplay)
                    .font(details.contentKind == .rtf ? .body : .system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .padding(12)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                if canEditContent {
                    Button("Edit Content", action: onEdit)
                        .keyboardShortcut("e", modifiers: .command)
                } else if details.isEditable {
                    Text("Content too large to edit inline — use Copy instead")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct MacClippyDetailsLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading details…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading clipboard details")
    }
}

struct MacClippyDetailsErrorView: View {
    let message: String
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("Could not load details")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Retry", action: onRetry)
                    .keyboardShortcut(.defaultAction)
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Could not load clipboard details. \(message)")
    }
}

final class MacClippyDetailsPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
