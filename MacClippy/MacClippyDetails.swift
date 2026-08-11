import AppKit
import SwiftUI
import MacClippyCore

enum MacClippyDetailsEditing: Equatable {
    case none
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

    @State private var contentDraft: String
    @State private var nameDraft: String
    @FocusState private var focusedField: DetailsFocusedField?

    private enum DetailsFocusedField: Hashable {
        case content
        case name
    }

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
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    contentSection
                    metadataSection
                    representationsSection
                }
                .padding(22)
            }
            Divider()
            footer
        }
        .frame(minWidth: 320, minHeight: 360)
        .background(.regularMaterial)
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

    private var metadataSection: some View {
        section("Metadata") {
            metadataRow("Source", details.sourceAppBundleID ?? "Unknown")
            metadataRow("Created", details.created.formatted(date: .abbreviated, time: .shortened))
            metadataRow("Modified", details.modified.formatted(date: .abbreviated, time: .shortened))
            metadataRow("Accessed", details.lastAccessed?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
            metadataRow("Access count", "\(details.frequency)")
            HStack {
                Text("Name").foregroundStyle(.secondary)
                Spacer()
                if editing == .name {
                    TextField("Name", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .focused($focusedField, equals: .name)
                        .onSubmit { onSaveName(nameDraft) }
                    Button("Save") { onSaveName(nameDraft) }
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel", action: onCancelEdit)
                } else {
                    Text(details.customLabel ?? "Not set")
                        .lineLimit(1)
                    Button("Rename", action: onRename)
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
            if let ocrText = details.ocrText, !ocrText.isEmpty {
                metadataRow("OCR", ocrText)
            }
            if !details.pinboardNames.isEmpty {
                metadataRow("Pinboards", details.pinboardNames.joined(separator: ", "))
            }
            if let dimensions = details.imageDimensions {
                metadataRow("Image", "\(Int(dimensions.width)) × \(Int(dimensions.height)) px")
            }
            if !details.fileURLs.isEmpty {
                metadataRow("Files", "\(details.fileURLs.count)")
                ForEach(details.fileURLs, id: \.self) { url in
                    Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private func focusField(for editing: MacClippyDetailsEditing) {
        let target: DetailsFocusedField?
        switch editing {
        case .content: target = .content
        case .name: target = .name
        case .none: target = nil
        }
        DispatchQueue.main.async {
            focusedField = target
        }
    }

    private func resetDrafts(for editing: MacClippyDetailsEditing) {
        switch editing {
        case .content:
            contentDraft = details.textContent ?? ""
        case .name:
            nameDraft = details.customLabel ?? ""
        case .none:
            contentDraft = details.textContent ?? ""
            nameDraft = details.customLabel ?? ""
        }
    }

    private var representationsSection: some View {
        section("Retained representations") {
            if details.representations.isEmpty {
                Text("No additional representations retained.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(details.representations) { representation in
                    HStack(spacing: 8) {
                        Image(systemName: representation.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(representation.isAvailable ? .green : .orange)
                        Text(representation.uti)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer()
                        Text(representation.payloadState.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(representation.byteCount), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Copy", action: onCopy)
            if let onPlainCopy { Button("Plain Text", action: onPlainCopy) }
            if editing == .none {
                Button("Paste", action: onPaste)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Paste", action: onPaste)
            }
            if let onTransformCopy, let onTransformPaste {
                Menu("Transform") {
                    ForEach(TextTransform.allCases, id: \.self) { transform in
                        Menu(transform.displayName) {
                            Button("Copy transformed") { onTransformCopy(transform) }
                            Button("Paste transformed") { onTransformPaste(transform) }
                        }
                    }
                }
            }
            Button("Pin", action: onPin)
            Spacer()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .padding(14)
    }

    private var contentDisplay: String {
        let fullText: String
        if let textContentPreview = details.textContentPreview {
            fullText = textContentPreview.isEmpty ? "(empty)" : textContentPreview
        } else if !details.fileURLs.isEmpty {
            fullText = details.fileURLs.map(\.path).joined(separator: "\n")
        } else if let dimensions = details.imageDimensions {
            fullText = "Image \(Int(dimensions.width)) × \(Int(dimensions.height)) px"
        } else {
            fullText = details.preview.isEmpty ? "(empty)" : details.preview
        }
        return MacClippyDockPreviewTextPolicy.displayText(for: fullText)
    }

    private var canEditContent: Bool {
        details.isEditable
            && (details.textContent?.count ?? 0) <= MacClippyDockPreviewTextPolicy.maxRenderedCharacters
    }

    private var iconName: String {
        switch details.contentKind {
        case .text, .html, .rtf: "doc.text"
        case .image: "photo"
        case .files: "folder"
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func metadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
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
