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
                        Text(representation.uti)
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
