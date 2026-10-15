import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import SwiftUI

struct MacClippyRenameItemEditor: View {
    enum Outcome {
        case save(name: String?)
        case cancel
    }

    let initialName: String?
    let onComplete: (Outcome) -> Void
    let onCancel: () -> Void

    @FocusState private var isFieldFocused: Bool
    @State private var text: String

    init(initialName: String?, onComplete: @escaping (Outcome) -> Void, onCancel: @escaping () -> Void) {
        self.initialName = initialName
        self.onComplete = onComplete
        self.onCancel = onCancel
        // Prefill with the current trimmed name so the user edits in place;
        // nil/blank becomes an empty field so Save removes the name.
        let trimmed = initialName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _text = State(initialValue: trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename")
                .font(.headline)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(save)
            Text("Leave blank to remove the name.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") {
                    onComplete(.cancel)
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(
            MacClippyDockTheme.panelStrongColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MacClippyDockTheme.lineColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .onAppear { isFieldFocused = true }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Blank removes the name: pass nil so the model/runtime normalizes the
        // stored value and rebuilds the index without the name term.
        onComplete(.save(name: trimmed.isEmpty ? nil : trimmed))
    }
}

struct MacClippyDockCardWell: View {
    var body: some View {
        TopRoundedRectangle(radius: MacClippyDockBackdropHolePolicy.panelCornerRadius)
            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
    }
}
