import SwiftUI
import MacClippyCore

extension MacClippyDetailsView {
    var metadataSection: some View {
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
                    TextField("Name", text: $editSession.nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .focused($focusedField, equals: .name)
                        .onSubmit { submitEdit(.save) }
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

    func focusField(for editing: MacClippyDetailsEditing) {
        let target: MacClippyDetailsFocusedField?
        switch editing {
        case .content: target = .content
        case .name: target = .name
        case .none: target = nil
        }
        DispatchQueue.main.async {
            focusedField = target
        }
    }

    func resetDrafts(for editing: MacClippyDetailsEditing) {
        editSession.resetDrafts()
    }

    var representationsSection: some View {
        section("Retained representations") {
            if details.representations.isEmpty {
                Text("No additional representations retained.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(details.representations) { representation in
                    HStack(spacing: 8) {
                        Image(
                            systemName: representation.isAvailable
                                ? "checkmark.circle.fill"
                                : "exclamationmark.circle"
                        )
                            .foregroundStyle(representation.isAvailable ? .green : .orange)
                        Text("Item \(representation.itemIndex + 1) · \(representation.uti)")
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer()
                        Text(representation.payloadState.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: Int64(representation.byteCount),
                                countStyle: .file
                            )
                        )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = editSession.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if editing != .none {
                    Button("Cancel", action: onCancelEdit)
                    Spacer()
                    if editSession.isSaving { ProgressView().controlSize(.small) }
                    Button("Save") { submitEdit(.save) }
                        .keyboardShortcut("s", modifiers: .command)
                    Button("Save & Paste") { submitEdit(.saveAndPaste) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Copy", action: onCopy)
                    Button("Paste", action: onPaste).keyboardShortcut(.defaultAction)
                    if details.isEditable {
                        Button("Edit", action: onEdit).keyboardShortcut("e", modifiers: .command)
                    }
                    Menu("More") {
                        if let onPlainCopy { Button("Copy plain text", action: onPlainCopy) }
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
                        Button("Delete permanently", role: .destructive, action: onDelete)
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
    }

    private func submitEdit(_ intent: MacClippyDetailsSaveIntent) {
        guard !editSession.isSaving else { return }
        if editing == .name {
            onSaveName(editSession.nameDraft, intent)
        } else {
            onSaveContent(editSession.contentDraft, intent)
        }
    }

    var contentDisplay: String {
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

    var canEditContent: Bool {
        details.isEditable
            && (details.textContent?.count ?? 0) <= MacClippyDockPreviewTextPolicy.maxRenderedCharacters
    }

    var iconName: String {
        switch details.contentKind {
        case .text, .html, .rtf: "doc.text"
        case .image: "photo"
        case .files: "folder"
        }
    }

    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    func metadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }
}
