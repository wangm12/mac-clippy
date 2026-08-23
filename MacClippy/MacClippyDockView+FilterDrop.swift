import AppKit
import SwiftUI
import UniformTypeIdentifiers

import MacClippyCore

extension MacClippyDockView {
    var filterPillRow: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterPill(
                        title: "All",
                        selected: model.selectedTab == .history
                    ) {
                        model.selectTab(.history)
                    }
                    ForEach(model.pinboards) { pinboard in
                        filterPill(
                            title: pinboard.name,
                            selected: model.selectedTab == .pinboard(pinboard.id),
                            isDropTarget: dropTargetPinboardID == pinboard.id,
                            isDropConfirmed: dropConfirmedPinboardID == pinboard.id,
                            accentHex: pinboard.colorHex
                        ) {
                            model.selectTab(.pinboard(pinboard.id))
                        }
                        .contextMenu { pinboardContextMenu(pinboard) }
                        .onDrop(
                            of: [UTType.utf8PlainText, UTType.text],
                            isTargeted: Binding(
                                get: { dropTargetPinboardID == pinboard.id },
                                set: { isTargeted in
                                    if isTargeted {
                                        dropTargetPinboardID = pinboard.id
                                    } else if dropTargetPinboardID == pinboard.id {
                                        dropTargetPinboardID = nil
                                    }
                                }
                            ),
                            perform: { providers in handleDrop(providers, on: pinboard) }
                        )
                    }
                    // Snippets is a normal filter pill beside All/pinboards so
                    // it is always reachable from the rail, not hidden behind
                    // the overflow menu.
                    filterPill(
                        title: "Snippets",
                        selected: model.selectedTab == .snippets,
                        isDropTarget: dropTargetSnippets,
                        isDropConfirmed: dropConfirmedSnippets
                    ) {
                        model.selectTab(.snippets)
                    }
                    .onDrop(
                        of: [UTType.utf8PlainText, UTType.text],
                        isTargeted: Binding(
                            get: { dropTargetSnippets },
                            set: { isTargeted in
                                dropTargetSnippets = isTargeted
                            }
                        ),
                        perform: handleSnippetDrop
                    )
                }
            }
            // +New is an action, not a filter, so it is split out of the pill
            // row as its own small icon button. Keeps the filter tabs pure.
            newCategoryButton
            // A direct Settings action keeps the gear one click from the
            // native preferences window.
            Button {
                MacClippySettingsWindowCoordinator.shared.bringToFront()
                showAboutPanel()
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(hoveredGear ? MacClippyDockTheme.accentColor : MacClippyDockTheme.textColor)
                    .frame(width: 36, height: 36)
                    .macClippyGlassEffectID("gear", in: headerGlassNamespace, enabled: !reduceMotion)
            }
            .macClippyChromeButtonStyle()
            .contentShape(Circle())
            .onHover { hovering in hoveredGear = hovering }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("macClippy.settingsButton")
            .help("Settings")
        }
    }

    // Keep the historical helper name to avoid changing the dock's call site.
    func showAboutPanel() {
        onOpenSettings()
    }

    // +New as a standalone icon button, separated from the filter pills so
    // the tab row stays semantically pure (filters only). Instant hover.
    var newCategoryButton: some View {
        Button {
            model.presentCreateCategory()
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(hoveredNewCategory ? MacClippyDockTheme.accentColor : MacClippyDockTheme.textColor)
                .frame(width: 36, height: 36)
                .macClippyGlassEffectID("newCategory", in: headerGlassNamespace, enabled: !reduceMotion)
        }
        .macClippyChromeButtonStyle()
        .contentShape(Circle())
        .onHover { hovering in hoveredNewCategory = hovering }
        .accessibilityLabel("Create category")
        .accessibilityIdentifier("macClippy.createCategoryButton")
        .help("Create category")
    }

    func filterPill(
        title: String,
        selected: Bool,
        isDropTarget: Bool = false,
        isDropConfirmed: Bool = false,
        accentHex: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let accentColor = accentHex.map { Color(macClippyHex: $0) }
        let isHovered = hoveredFilterPill == title
        let dropScale = reduceMotion ? 1 :
            (isDropConfirmed ? 1.08 : (isDropTarget ? 1.05 : 1))
        let ringWidth: CGFloat = highContrast ? 2 : (isDropConfirmed ? 2.5 : (isDropTarget ? 2 : MacClippyDockTheme.pillBorderWidth))
        let ringColor = isDropConfirmed ? (accentColor ?? MacClippyDockTheme.accentColor) :
            (isDropTarget ? MacClippyDockTheme.interactiveStrongBorder :
                (isHovered ? MacClippyDockTheme.pillHoverBorder : MacClippyDockTheme.pillRestBorder))
        return Button(action: action) {
            HStack(spacing: 6) {
                if let accentColor {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.body.weight(selected ? .bold : .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(MacClippyDockTheme.textColor)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .macClippyFilterChipStyle(
            selected: selected || isDropConfirmed,
            tint: accentColor ?? MacClippyDockTheme.accentColor
        )
        .overlay(
            Capsule()
                .inset(by: MacClippyDockTheme.pillBorderInset)
                .stroke(ringColor, lineWidth: ringWidth)
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "Selected" : "")
        .contentShape(Capsule())
        .scaleEffect(dropScale)
        .animation(
            MacClippyMotion.animation(MacClippyMotion.hoverAnimation, reduceMotion: reduceMotion),
            value: isDropTarget
        )
        .animation(
            MacClippyMotion.animation(MacClippyMotion.hoverAnimation, reduceMotion: reduceMotion),
            value: isDropConfirmed
        )
        .transaction { transaction in
            if !isDropTarget && !isDropConfirmed {
                transaction.animation = nil
            }
        }
        .onHover { hovering in
            guard MacClippyDockHoverPolicy.shouldApplyHover(
                hovering,
                pressedMouseButtons: NSEvent.pressedMouseButtons
            ) else { return }
            hoveredFilterPill = hovering ? title : (hoveredFilterPill == title ? nil : hoveredFilterPill)
        }
    }

    func handleDrop(_ providers: [NSItemProvider], on pinboard: MacClippyPinboardEntry) -> Bool {
        let expectedSession = model.currentSessionGeneration
        let typeIdentifier = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) }) != nil
            ? UTType.utf8PlainText.identifier
            : UTType.text.identifier
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(typeIdentifier) }) else {
            return false
        }
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            guard let data,
                  let payload = String(data: data, encoding: .utf8),
                  let recordID = MacClippyClipboardDropPolicy.recordID(from: payload) else { return }
            DispatchQueue.main.async {
                model.pin(recordID: recordID, to: pinboard, expectedSession: expectedSession) { success in
                    guard success, model.currentSessionGeneration == expectedSession else { return }
                    dropConfirmationGeneration &+= 1
                    let confirmationGeneration = dropConfirmationGeneration
                    dropConfirmedPinboardID = pinboard.id
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(MacClippyMotion.dropConfirmationLifetime * 1_000_000_000))
                        guard dropConfirmationGeneration == confirmationGeneration,
                              dropConfirmedPinboardID == pinboard.id,
                              model.currentSessionGeneration == expectedSession else { return }
                        dropConfirmedPinboardID = nil
                    }
                }
            }
        }
        return true
    }

    func handleSnippetDrop(_ providers: [NSItemProvider]) -> Bool {
        let expectedSession = model.currentSessionGeneration
        let typeIdentifier = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) }) != nil
            ? UTType.utf8PlainText.identifier
            : UTType.text.identifier
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(typeIdentifier) }) else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
            guard let data,
                  let payload = String(data: data, encoding: .utf8),
                  let recordID = MacClippyClipboardDropPolicy.recordID(from: payload) else { return }
            DispatchQueue.main.async {
                model.createSnippet(from: recordID, expectedSession: expectedSession) { success in
                    guard success, model.currentSessionGeneration == expectedSession else { return }
                    dropConfirmationGeneration &+= 1
                    let confirmationGeneration = dropConfirmationGeneration
                    dropConfirmedSnippets = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(MacClippyMotion.dropConfirmationLifetime * 1_000_000_000))
                        guard dropConfirmationGeneration == confirmationGeneration,
                              dropConfirmedSnippets,
                              model.currentSessionGeneration == expectedSession else { return }
                        dropConfirmedSnippets = false
                    }
                }
            }
        }
        return true
    }

    func actionFeedbackView(_ feedback: MacClippyDockActionFeedback) -> some View {
        Label(feedback.title, systemImage: feedback.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(MacClippyDockTheme.textColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(MacClippyDockTheme.panelStrongColor, in: Capsule())
            .pillBorder(MacClippyDockTheme.pillRestBorder)
            .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
            .lineLimit(1)
            .allowsHitTesting(false)
    }
}
