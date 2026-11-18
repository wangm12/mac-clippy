import MacClippyCore
import SwiftUI

struct MacClippySnippetDraft: Sendable {
    let name: String
    let trigger: String?
    let body: String
    let folder: String?
}

@MainActor
final class MacClippySnippetEditorState: ObservableObject {
    let isEditing: Bool
    @Published var name: String
    @Published var trigger: String
    @Published var folder: String
    @Published var body: String
    @Published var isSubmitting = false
    @Published var errorMessage: String?
    private let originalName: String
    private let originalTrigger: String
    private let originalFolder: String
    private let originalBody: String

    var isDirty: Bool {
        name != originalName || trigger != originalTrigger || folder != originalFolder || body != originalBody
    }

    init(snippet: MacClippySnippetEntry? = nil) {
        isEditing = snippet != nil
        name = snippet?.name ?? ""
        trigger = snippet?.trigger ?? ""
        folder = snippet?.folder ?? ""
        body = snippet?.body ?? ""
        originalName = snippet?.name ?? ""
        originalTrigger = snippet?.trigger ?? ""
        originalFolder = snippet?.folder ?? ""
        originalBody = snippet?.body ?? ""
    }
}

@MainActor
struct MacClippyCreateSnippetEditor: View {
    @ObservedObject var form: MacClippySnippetEditorState
    let onCreate: (String, String?, String, String?, @escaping (Bool) -> Void) -> Void
    let onCancel: () -> Void

    private enum Field {
        case name
        case trigger
        case folder
        case body
    }

    @FocusState private var focusedField: Field?
    init(
        form: MacClippySnippetEditorState? = nil,
        onCreate: @escaping (String, String?, String, String?, @escaping (Bool) -> Void) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.form = form ?? MacClippySnippetEditorState()
        self.onCreate = onCreate
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(form.isEditing ? "Edit snippet" : "New snippet")
                .font(.headline)
            Text("Save reusable text and optionally give it a ;trigger for automatic expansion.")
                .font(.caption)
                .foregroundStyle(MacClippyDockTheme.mutedColor)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $form.name)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .name)
                .onSubmit { focusedField = .trigger }

            VStack(alignment: .leading, spacing: 5) {
                TextField("Trigger (optional, e.g. ;email)", text: $form.trigger)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .trigger)
                    .onSubmit { focusedField = .folder }
                Text("Leave blank if you only want to copy or paste it manually.")
                    .font(.caption2)
                    .foregroundStyle(MacClippyDockTheme.muted2Color)
            }

            VStack(alignment: .leading, spacing: 5) {
                TextField("Folder (optional, e.g. Work/Email)", text: $form.folder)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .folder)
                    .onSubmit { focusedField = .body }
                Text("Use / to nest folders. Body can include {{date}}, {{time}}, and {{clipboard}}.")
                    .font(.caption2)
                    .foregroundStyle(MacClippyDockTheme.muted2Color)
            }

            TextEditor(text: $form.body)
                .font(.body)
                .focused($focusedField, equals: .body)
                .frame(height: 110)
                .padding(5)
                .background(
                    MacClippyDockTheme.cardColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(MacClippyDockTheme.lineColor, lineWidth: 1)
                }
                .accessibilityLabel("Snippet body")
                .accessibilityHint("Enter reusable text for this snippet")

            if let error = form.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(form.isSubmitting)
                Button(form.isEditing ? "Save" : "Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || form.isSubmitting)
            }
        }
        .padding(28)
        .frame(width: 440, height: 468, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focusedField = .name }
        .disabled(form.isSubmitting)
    }

    private var canCreate: Bool {
        !form.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !form.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        guard canCreate, !form.isSubmitting else { return }
        form.errorMessage = nil
        form.isSubmitting = true
        let normalizedTrigger = form.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFolder = form.folder.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(
            form.name.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedTrigger.isEmpty ? nil : normalizedTrigger,
            form.body,
            normalizedFolder.isEmpty ? nil : normalizedFolder,
            { _ in
                form.isSubmitting = false
            }
        )
    }
}
