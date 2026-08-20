import SwiftUI

extension MacClippyDockView {
    var header: some View {
        ZStack {
            if model.hasMultipleSelection {
                selectionHeader
                    .transition(MacClippyMotion.headerTransition(reduceMotion: reduceMotion))
            } else {
                topRow
                    .transition(MacClippyMotion.headerTransition(reduceMotion: reduceMotion))
            }
        }
    }

    // Selection-mode header: count + Cancel on the left, primary/secondary
    // actions in the center, destructive actions on the right. Replaces the
    // old bottom action bar so the eye never leaves the card area.
    var selectionHeader: some View {
        GeometryReader { proxy in
            HStack(spacing: 8) {
                // Left: count badge (with number flip) + Cancel/Esc.
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("\(model.selectionCount)")
                            .id(model.selectionCount)
                            .transition(MacClippyMotion.numberFlipTransition(reduceMotion: reduceMotion))
                        Text("selected")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MacClippyDockTheme.textColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MacClippyDockTheme.accentSoftColor, in: Capsule())
                    .animation(MacClippyMotion.animation(MacClippyMotion.focusAnimation, reduceMotion: reduceMotion), value: model.selectionCount)

                    Button {
                        model.clearSelection()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                            Text("Cancel")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(MacClippyDockTheme.mutedColor)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                    }
                    .buttonStyle(.plain)
                    .background(Capsule().fill(MacClippyDockTheme.cardColor.opacity(0.5)))
                    .pillBorder(MacClippyDockTheme.pillRestBorder)
                    .help("Exit selection (Esc)")
                }

                Spacer(minLength: 8)

                // Center/right actions, horizontally scrollable on narrow widths.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        SelectionBarButton("Paste all", systemImage: "arrow.down.doc", emphasis: .primary) {
                            model.pasteSelectedAll(completion: { [weak model] in
                                _ = model
                                onClose()
                            })
                        }
                        .staggeredAppearance(index: 0, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        SelectionBarButton("Queue paste", systemImage: "list.number") {
                            model.pasteQueued(completion: { [weak model] in
                                _ = model
                                onClose()
                            })
                        }
                        .staggeredAppearance(index: 1, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        SelectionBarButton("Copy all", systemImage: "doc.on.doc") {
                            model.copySelectedAll()
                        }
                        .staggeredAppearance(index: 2, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        if model.batchPinTarget != nil {
                            SelectionBarButton("Pin", systemImage: "pin") {
                                model.pinSelected()
                            }
                            .staggeredAppearance(index: 3, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        }
                        SelectionBarButton("Delete", systemImage: "trash", role: .destructive) {
                            model.deleteSelected()
                        }
                        .staggeredAppearance(index: 4, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        SelectionBarButton("Clear", systemImage: "xmark", role: .destructive) {
                            model.clearSelection()
                        }
                        .staggeredAppearance(index: 5, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: proxy.size.width * 0.62, alignment: .trailing)
            }
        }
        .onAppear { actionBarAppeared = true }
        .onDisappear { actionBarAppeared = false }
    }

    // Single horizontal top row: the search field takes about 42% of the
    // available row width, the category/tag pills share the same row to its
    // right. Cmd+K focuses the SwiftUI search field (wired in the dock
    // controller); the field no longer auto-focuses on dock show — the dock
    // is keyboard-first and the first card is focusable. Settings opens via
    // a direct gear button. GeometryReader sizes the search field to ~42% of
    // the row width (clamped so it stays usable on very narrow and very wide
    // screens) without animating width on screen changes.
    var topRow: some View {
        GeometryReader { proxy in
            let available = proxy.size.width
            let searchWidth = max(240, min(available * 0.42, 640))
            HStack(spacing: 10) {
                searchField
                    .frame(width: searchWidth, alignment: .leading)
                filterPillRow
            }
        }
        .onAppear {
            // Keyboard-first: do not steal focus into the search field on
            // launch. Reduce Motion is still reported to the controller.
            onReduceMotionChange(accessibilityReduceMotion)
        }
        .onChange(of: model.searchFocusRequest) { _, _ in isSearchFocused = true }
        .onChange(of: model.searchFocusReset) { _, _ in isSearchFocused = false }
    }

    var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                // Plain magnifying-glass icon, no circular badge (reference).
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MacClippyDockTheme.muted2Color)
                TextField("Search clipboard...", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .foregroundStyle(MacClippyDockTheme.textColor)
                    .focused($isSearchFocused)
                    .onChange(of: isSearchFocused) { _, focused in
                        onSearchModeChange(focused)
                    }
                    .onTapGesture {
                        isSearchFocused = true
                        onSearchModeChange(true)
                    }
                    .onSubmit { model.reload() }
                    .help(
                        "Search clipboard history. Add clauses like type:text, type:url, app:name, name:work, "
                            + "has:name, has:ocr, before:YYYY-MM-DD, after:YYYY-MM-DD. Quote a phrase to keep "
                            + "it together, and add * for a prefix (clip*)."
                    )
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        isSearchFocused = true
                        onSearchModeChange(true)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MacClippyDockTheme.muted2Color)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                    .help("Clear search")
                    .transition(MacClippyMotion.fadeTransition(reduceMotion: reduceMotion))
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(MacClippyDockTheme.panelStrongColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        isSearchFocused ? MacClippyDockTheme.accentColor.opacity(0.32) : MacClippyDockTheme.lineColor,
                        lineWidth: 1
                    )
            }
            .overlay {
                if isSearchFocused {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(MacClippyDockTheme.accentSoftColor, lineWidth: 3)
                }
            }
        }
    }
}
