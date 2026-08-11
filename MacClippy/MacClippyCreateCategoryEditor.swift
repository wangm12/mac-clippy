import AppKit
import SwiftUI

import MacClippyCore

struct MacClippyCreateCategoryEditor: View {
    let onCreate: (String, String, @escaping (Bool) -> Void) -> Void
    let onCancel: () -> Void
    @FocusState private var isNameFocused: Bool
    @State private var name = ""
    @State private var selectedColor = MacClippyCategoryColorPolicy.palette[0]
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New category")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(create)
            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(MacClippyCategoryColorPolicy.palette, id: \.self) { color in
                        Button {
                            guard !isSubmitting else { return }
                            selectedColor = color
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(macClippyHex: color))
                                    .frame(width: 24, height: 24)
                                if selectedColor == color {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .shadow(color: .black.opacity(0.45), radius: 1)
                                    Circle()
                                        .stroke(MacClippyDockTheme.accentColor, lineWidth: 2)
                                        .frame(width: 30, height: 30)
                                }
                            }
                            // Keep the color dot compact while giving the
                            // entire 40pt control a reliable pointer target.
                            .frame(width: 40, height: 40)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose \(colorName(for: color))")
                        .accessibilityValue(selectedColor == color ? "Selected" : "Not selected")
                        .accessibilityAddTraits(selectedColor == color ? .isSelected : [])
                        .accessibilityIdentifier("macClippy.categoryColor.\(colorName(for: color))")
                        .disabled(isSubmitting)
                    }
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button {
                    create()
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                        Text("Creating…")
                    } else {
                        Text("Create")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            }
        }
        .padding(28)
        .frame(width: 460)
        .background(MacClippyDockTheme.panelStrongColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MacClippyDockTheme.lineColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .onAppear {
            // Wait until the overlay is mounted in the existing Dock panel so
            // this field wins focus over the field that opened the modal.
            DispatchQueue.main.async { isNameFocused = true }
        }
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !isSubmitting else { return }
        errorMessage = nil
        isSubmitting = true
        onCreate(trimmedName, selectedColor) { succeeded in
            isSubmitting = false
            if !succeeded {
                errorMessage = "Couldn’t create category. Try again."
            }
        }
    }

    private func colorName(for color: String) -> String {
        MacClippyCategoryColorPolicy.name(for: color)
    }
}
