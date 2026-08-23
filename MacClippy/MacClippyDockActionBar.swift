import AppKit
import Foundation
import SwiftUI

import MacClippyCore
import MacClippyPlatform

struct MacClippyCreateSnippetEditor: View {
    let onCreate: (String, String?, String, @escaping (Bool) -> Void) -> Void
    let onCancel: () -> Void

    private enum Field {
        case name
        case trigger
        case body
    }

    @FocusState private var focusedField: Field?
    @State private var name = ""
    @State private var trigger = ""
    @State private var snippetBody = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New snippet")
                .font(.headline)
            Text("Save reusable text and optionally give it a ;trigger for automatic expansion.")
                .font(.caption)
                .foregroundStyle(MacClippyDockTheme.mutedColor)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .name)
                .onSubmit { focusedField = .trigger }

            VStack(alignment: .leading, spacing: 5) {
                TextField("Trigger (optional, e.g. ;email)", text: $trigger)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .trigger)
                    .onSubmit { focusedField = .body }
                Text("Leave blank if you only want to copy or paste it manually.")
                    .font(.caption2)
                    .foregroundStyle(MacClippyDockTheme.muted2Color)
            }

            TextEditor(text: $snippetBody)
                .font(.body)
                .focused($focusedField, equals: .body)
                .frame(height: 110)
                .padding(5)
                .background(MacClippyDockTheme.cardColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(MacClippyDockTheme.lineColor, lineWidth: 1)
                }
                .accessibilityLabel("Snippet body")
                .accessibilityHint("Enter reusable text for this snippet")

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || isSubmitting)
            }
        }
        .padding(28)
        .frame(width: 440, height: 410, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focusedField = .name }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !snippetBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        guard canCreate, !isSubmitting else { return }
        isSubmitting = true
        let normalizedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(
            name.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedTrigger.isEmpty ? nil : normalizedTrigger,
            snippetBody,
            { _ in
                isSubmitting = false
            }
        )
    }
}

struct MacClippyRenameCategoryEditor: View {
    let initialName: String
    let onRename: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var isNameFocused: Bool
    @State private var name: String

    init(initialName: String, onRename: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.initialName = initialName
        self.onRename = onRename
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename category")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(rename)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 310)
        .background(MacClippyDockTheme.panelStrongColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MacClippyDockTheme.lineColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .onAppear { isNameFocused = true }
    }

    private func rename() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        onRename(trimmedName)
    }
}

struct MacClippyConfirmDeleteCategoryEditor: View {
    let categoryName: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete \"\(categoryName)\"?")
                .font(.headline)
            Text("The category will be removed, but its clipboard items will stay in All history.")
                .font(.body)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(MacClippyDockTheme.panelStrongColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MacClippyDockTheme.lineColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
    }
}

extension Color {
    init(macClippyHex value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard normalized.count == 6,
              let hex = UInt64(normalized, radix: 16) else {
            self = .accentColor
            return
        }
        self.init(
            nsColor: NSColor(
                calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        )
    }
}

// Multi-select action button with three visual tiers per design.md: primary
// (accent fill, the single most important action), destructive (semantic red
// text + red hover ring for Delete/Clear), and default (neutral capsule).
// Hover adds a subtle ring so every interactive surface has an indicator.
struct SelectionBarButton: View {
    enum Emphasis { case `default`, primary, destructive }

    let title: String
    let systemImage: String
    let role: ButtonRole?
    let emphasis: Emphasis
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isHovered = false

    private var reduceMotion: Bool {
        MacClippyMotion.shouldReduceMotion(swiftUI: accessibilityReduceMotion)
    }

    init(_ title: String, systemImage: String, role: ButtonRole? = nil, emphasis: Emphasis = .default, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.emphasis = role == .destructive ? .destructive : emphasis
        self.action = action
    }

    var body: some View {
        if #available(macOS 26, *) {
            tahoeBody
        } else {
            fallbackBody
        }
    }

    @available(macOS 26, *)
    @ViewBuilder
    private var tahoeBody: some View {
        let isDestructive = emphasis == .destructive
        let isPrimary = emphasis == .primary
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(
                    isPrimary ? MacClippyDockTheme.accentForegroundColor :
                    (isDestructive ? Color.red.opacity(0.9) : MacClippyDockTheme.textColor)
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(minHeight: 34)
        }
        .modifier(MacClippySelectionGlassStyle(isPrimary: isPrimary))
        .overlay {
            if !isPrimary {
                Capsule()
                    .inset(by: MacClippyDockTheme.pillBorderInset)
                    .stroke(selectionRingColor(isDestructive: isDestructive), lineWidth: MacClippyDockTheme.pillBorderWidth)
            }
        }
        .onHover { hovering in isHovered = hovering }
        .animation(MacClippyMotion.animation(MacClippyMotion.hoverAnimation, reduceMotion: reduceMotion), value: isHovered)
    }

    @ViewBuilder
    private var fallbackBody: some View {
        let isDestructive = emphasis == .destructive
        let isPrimary = emphasis == .primary
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(
                    isPrimary ? MacClippyDockTheme.accentForegroundColor :
                    (isDestructive ? Color.red.opacity(0.9) : MacClippyDockTheme.textColor)
                )
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .frame(minHeight: 28)
                .background(
                    isPrimary
                        ? MacClippyDockTheme.accentColor
                        : MacClippyDockTheme.cardColor.opacity(isHovered ? 0.85 : 0.55),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .inset(by: MacClippyDockTheme.pillBorderInset)
                        .stroke(
                            isPrimary ? Color.clear : selectionRingColor(isDestructive: isDestructive),
                            lineWidth: MacClippyDockTheme.pillBorderWidth
                        )
                )
                .shadow(color: isPrimary ? MacClippyDockTheme.accentColor.opacity(0.25) : .clear, radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .animation(MacClippyMotion.animation(MacClippyMotion.hoverAnimation, reduceMotion: reduceMotion), value: isHovered)
    }

    private func selectionRingColor(isDestructive: Bool) -> Color {
        if isDestructive {
            return Color.red.opacity(isHovered ? 0.7 : 0.28)
        }
        return isHovered
            ? MacClippyDockTheme.interactiveHoverBorder
            : MacClippyDockTheme.interactiveRestBorder
    }
}

private struct MacClippySelectionGlassStyle: ViewModifier {
    let isPrimary: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            if isPrimary {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            content.buttonStyle(.plain)
        }
    }
}

struct TopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + radius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

// A screen-level toast for copy confirmations. Shown in its own
// floating panel so a double-click copy reads as a system indicator, not an
// in-dock overlay. Auto-dismissed by the controller after ~1.2s.
struct MacClippyCopyToastView: View {
    let title: String
    var showsShadow = true
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
            Text(title)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(MacClippyDockTheme.textColor)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(
            Capsule()
                .fill(MacClippyDockTheme.panelStrongColor)
                .shadow(
                    color: showsShadow ? .black.opacity(0.18) : .clear,
                    radius: showsShadow ? 16 : 0,
                    y: showsShadow ? 6 : 0
                )
        )
    }
}
