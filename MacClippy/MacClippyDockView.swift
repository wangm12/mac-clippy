import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

import MacClippyCore
import MacClippyPlatform

struct MacClippyCardHoverModifier: ViewModifier {
    let enabled: Bool
    let reduceMotion: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let active = enabled && isHovered
        return content
            // Keep hover feedback on the card surface without moving or
            // shadowing the entire card. During a horizontal trackpad scroll,
            // the pointer crosses card boundaries while the content moves;
            // animated offsets and shadow filters on every card can then
            // compete with the scroll compositor and feel sticky.
            .overlay {
                RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous)
                    .stroke(
                        MacClippyDockTheme.accentColor.opacity(active ? 0.28 : 0),
                        lineWidth: 1
                    )
            }
            .animation(MacClippyMotion.animation(MacClippyMotion.focusAnimation, reduceMotion: reduceMotion), value: active)
            .onHover { hovering in
                isHovered = enabled && hovering
            }
    }
}

struct MacClippyDockView: View {
    @ObservedObject var model: MacClippyDockModel
    let onClose: @MainActor @Sendable () -> Void
    let onCreateSnippet: () -> Void
    let onOpenSettings: () -> Void
    let onEnterPickerMode: () -> Void
    let onPreview: () -> Void
    let onSearchModeChange: (Bool) -> Void
    let onModalPresentationChange: (Bool) -> Void
    let onReduceMotionChange: (Bool) -> Void
    let onLayoutHeightChange: (Bool) -> Void
    // Screen-level copy toast callback. When the model surfaces a .copied
    // feedback, the view calls this so the controller can show a floating
    // toast outside the dock instead of an in-panel overlay.
    let onCopyToast: (String) -> Void
    @Environment(\.accessibilityReduceMotion) var accessibilityReduceMotion
    @FocusState var isSearchFocused: Bool
    @AccessibilityFocusState var modalAccessibilityFocused: Bool
    @State var dropTargetPinboardID: RecordID?
    @State var dropConfirmedPinboardID: RecordID?
    @State var dropTargetSnippets = false
    @State var dropConfirmedSnippets = false
    @State var dropConfirmationGeneration: UInt = 0
    // P2a: inline custom-name editor state is owned by the dock model and is
    // presented inside this panel, so keyboard events stay with the editor.
    // Pointer hover state for the +New category pill. Hover is border-only:
    // the dashed capsule border swaps to the accent color and thickens
    // slightly. There is no hover background fill, no hover foreground-color
    // change, and no vertical lift, so the pill never moves. Reduce Motion
    // keeps the instant border state.
    @State var hoveredNewCategory = false
    // Hover state for filter/category pills so every interactive rail surface
    // has an instant hover indicator, not just the +New pill.
    @State var hoveredFilterPill: String?
    // Gear/About button hover so it shares the same hover treatment as the
    // other circular icon buttons (+New).
    @State var hoveredGear = false
    // One-shot flag for the action bar staggered button fade-in. Set on the
    // bar's first onAppear so buttons orchestrate left-to-right once.
    @State var actionBarAppeared = false
    @State var shouldRestoreSearchFocus = false
    @State var modalFocusGeneration: UInt = 0
    @State var sourcePresentationGeneration: UInt = 0

    var reduceMotion: Bool {
        MacClippyMotion.shouldReduceMotion(swiftUI: accessibilityReduceMotion)
    }

    var highContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            || NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
    }

    var body: some View {
        VStack(spacing: 10) {
            // Header morphs in place between search mode and selection mode.
            // Both modes occupy the same fixed 48pt row, so switching never
            // resizes the panel — no vertical reflow, no dock resize. Selection
            // mode shows the count, a Cancel/Esc button, the action buttons,
            // and destructive Delete/Clear, all within the header.
            header
                .frame(height: 48)
                // Keep the selection morph scoped to the header. An animation
                // on the dock root also animates the carousel transaction when
                // selection changes, which can make its scroll position appear
                // to jump even though pointer selection never requests a
                // scroll.
                .transaction { transaction in
                    transaction.animation = reduceMotion
                        ? nil
                        : (model.hasMultipleSelection
                            ? MacClippyMotion.actionBarEnterSpring
                            : MacClippyMotion.actionBarExit)
                }
            // The carousel container fills the width but does not force a
            // vertical stretch: the populated horizontal carousels constrain
            // themselves to MacClippyDockCardMetrics.carouselHeight, while the
            // loading/error/empty branches keep their own maxHeight: .infinity
            // so they center within the available panel space without adding
            // decorative edge overlays over the first and last cards.
            carousel
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Vibrancy material shell over the cool-neutral backdrop. The AppKit
        // backdrop paints the cool white/gray gradient; this thin material adds
        // the reference liquid-glass feel without hiding content.
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.55)
                .background(MacClippyDockTheme.panelStrongColor.opacity(0.18))
                .clipShape(TopRoundedRectangle(radius: 22))
                .overlay(TopRoundedRectangle(radius: 22).stroke(MacClippyDockTheme.lineColor, lineWidth: 1))
                .allowsHitTesting(false)
        )
        .clipShape(TopRoundedRectangle(radius: 22))
        .accessibilityHidden(model.modal != nil)
        .overlay {
            modalOverlay
        }
        .overlay(alignment: .topTrailing) {
            // In-panel feedback overlay skips .copied — copy confirmations get
            // a screen-level toast via onCopyToast instead, so the indicator
            // survives a dock close and reads like paste feedback.
            if let actionFeedback = model.actionFeedback, !actionFeedback.isCopyFeedback {
                actionFeedbackView(actionFeedback)
                    .padding(.top, 56)
                    .padding(.trailing, 18)
                    .transition(MacClippyMotion.fadeTransition(reduceMotion: reduceMotion))
                    .animation(
                        MacClippyMotion.animation(MacClippyMotion.actionFeedbackAnimation, reduceMotion: reduceMotion),
                        value: model.actionFeedback
                    )
            }
        }
        .overlay(alignment: .topLeading) {
            if let actionError = model.actionError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MacClippyDockTheme.accentColor)
                    Text(actionError)
                        .font(.caption)
                        .foregroundStyle(MacClippyDockTheme.textColor)
                        .lineLimit(2)
                    Button("Dismiss") {
                        model.clearActionError()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel("Dismiss error")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(MacClippyDockTheme.lineColor, lineWidth: 1))
                .padding(.top, 56)
                .padding(.leading, 18)
                .transition(MacClippyMotion.fadeTransition(reduceMotion: reduceMotion))
            }
        }
        .onReceive(model.$actionFeedback) { feedback in
            if let feedback, feedback.isCopyFeedback {
                onCopyToast(feedback.title)
            }
            if let feedback, let app = NSApp {
                NSAccessibility.post(
                    element: app,
                    notification: .announcementRequested,
                    userInfo: [.announcement: feedback.title]
                )
            }
        }
        .onChange(of: model.errorMessage) { _, errorMessage in
            guard let errorMessage, let app = NSApp else { return }
            NSAccessibility.post(
                element: app,
                notification: .announcementRequested,
                userInfo: [.announcement: errorMessage]
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .macClippySourceAppPresentationDidResolve)) { _ in
            sourcePresentationGeneration &+= 1
        }
        // Read the token so cards that initially rendered a source placeholder
        // are recomputed once the background LaunchServices lookup completes.
        .animation(nil, value: sourcePresentationGeneration)
        .onChange(of: accessibilityReduceMotion) { _, value in onReduceMotionChange(value) }
        .onChange(of: model.isLoading) { wasLoading, isLoading in
            guard wasLoading, !isLoading else { return }
            announceSearchResultsIfNeeded()
        }
        .onAppear {
            // Keyboard-first: do NOT auto-focus the search field on launch.
            // The first card is focusable; Cmd+K still focuses search on
            // demand via the controller key monitor.
            onReduceMotionChange(accessibilityReduceMotion)
        }
        .onChange(of: model.hasMultipleSelection) { _, hasMultipleSelection in
            onLayoutHeightChange(hasMultipleSelection)
        }
        .onChange(of: model.modal) { _, modal in
            modalFocusGeneration &+= 1
            let focusGeneration = modalFocusGeneration
            // The modal is an in-panel overlay, so the search TextField can
            // still be the AppKit first responder when the overlay appears.
            // Release it before the modal editor requests focus; otherwise
            // printable keys continue to land in the main search field.
            if modal != nil {
                shouldRestoreSearchFocus = isSearchFocused
                isSearchFocused = false
                onSearchModeChange(false)
                DispatchQueue.main.async {
                    guard modalFocusGeneration == focusGeneration, model.modal != nil else { return }
                    modalAccessibilityFocused = true
                }
            } else {
                modalAccessibilityFocused = false
                if shouldRestoreSearchFocus {
                    DispatchQueue.main.async {
                        guard modalFocusGeneration == focusGeneration, model.modal == nil else { return }
                        isSearchFocused = true
                        shouldRestoreSearchFocus = false
                    }
                }
            }
            onModalPresentationChange(modal != nil)
        }
    }
}

// P2a: clipboard item rename editor. Presented from a clipboard card context
// menu and the focused-card Rename accessibility action. The text field is
// prefilled with the card's current name (empty when none is stored). Save
// (defaultAction / Return) trims the entered text and returns .save; a blank
// trimmed value removes the name. Cancel (cancelAction / Esc) returns .cancel
// without touching the store. The editor never writes to the pasteboard, so it
// has no copy/paste side effects. The parent owns the actual model.renameItem
// call so this view stays free of runtime dependencies.
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
        .background(MacClippyDockTheme.panelStrongColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
