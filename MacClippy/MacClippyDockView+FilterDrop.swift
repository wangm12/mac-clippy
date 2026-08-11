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
                            count: pinboard.itemCount,
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(hoveredGear ? MacClippyDockTheme.accentColor : MacClippyDockTheme.muted2Color)
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(
                            hoveredGear
                                ? MacClippyDockTheme.cardColor.opacity(0.60)
                                : MacClippyDockTheme.cardColor.opacity(0.50)
                        )
                    )
                    .circleBorder(hoveredGear ? MacClippyDockTheme.pillHoverBorder : MacClippyDockTheme.pillRestBorder)
                    .padding(5)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(hoveredNewCategory ? MacClippyDockTheme.accentColor : MacClippyDockTheme.muted2Color)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(
                        hoveredNewCategory
                            ? MacClippyDockTheme.cardColor.opacity(0.60)
                            : MacClippyDockTheme.cardColor.opacity(0.50)
                    )
                )
                .circleBorder(
                    hoveredNewCategory
                        ? MacClippyDockTheme.pillHoverBorder
                        : MacClippyDockTheme.pillRestBorder
                )
                .padding(5)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .onHover { hovering in hoveredNewCategory = hovering }
        .accessibilityLabel("Create category")
        .accessibilityIdentifier("macClippy.createCategoryButton")
        .help("Create category")
    }

    func filterPill(
        title: String,
        count: Int? = nil,
        selected: Bool,
        isDropTarget: Bool = false,
        isDropConfirmed: Bool = false,
        accentHex: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let accentColor = accentHex.map { Color(macClippyHex: $0) }
        let isHovered = hoveredFilterPill == title
        let borderColor = isDropConfirmed ? (accentColor?.opacity(1) ?? MacClippyDockTheme.accentColor) :
            (isDropTarget ? (accentColor?.opacity(0.95) ?? MacClippyDockTheme.accentColor.opacity(0.9)) :
            (selected ? (highContrast ? MacClippyDockTheme.textColor : (accentColor ?? MacClippyDockTheme.pillRestBorder)) :
             (isHovered ? MacClippyDockTheme.pillHoverBorder : .clear)))
        let fillColor = isDropConfirmed
            ? (accentColor ?? MacClippyDockTheme.accentColor).opacity(0.9)
            : (isDropTarget
                ? (accentColor ?? MacClippyDockTheme.accentColor).opacity(0.72)
                : (selected
                    ? (accentColor?.opacity(0.16) ?? MacClippyDockTheme.cardColor.opacity(0.92))
                    : (isHovered ? MacClippyDockTheme.cardColor.opacity(0.60) : MacClippyDockTheme.cardColor.opacity(0.36))))
        return Button(action: action) {
            HStack(spacing: 5) {
                if let accentColor {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 6, height: 6)
                }
                Text(title)
                    .font(.caption.weight(selected ? .bold : .semibold))
                    .lineLimit(1)
                if let count, let countLabel = MacClippyDockCategoryRailPolicy.countLabel(for: count) {
                    Text(countLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(selected ? MacClippyDockTheme.mutedColor : MacClippyDockTheme.muted2Color)
                }
            }
            // Keep category colors as a dot/border accent. Text must resolve
            // against the pill surface in both appearances; custom accent
            // colors are not guaranteed to meet contrast on dark mode.
            .foregroundStyle(
                isDropConfirmed || isDropTarget
                    ? MacClippyDockTheme.textColor
                    : selected
                        ? MacClippyDockTheme.textColor
                        : isHovered
                            ? MacClippyDockTheme.textColor
                            : MacClippyDockTheme.mutedColor
            )
            .padding(.horizontal, 10)
            // Use a fixed capsule shape for both fill and stroke so the border
            // is drawn as part of the shape, not an overlay that can be clipped
            // by the ScrollView or the row's vertical centering.
            .frame(height: 30)
            .background(Capsule().fill(fillColor))
            .overlay(
                Capsule()
                    .inset(by: MacClippyDockTheme.pillBorderInset)
                    .stroke(borderColor, lineWidth: highContrast ? 2 : (isDropConfirmed ? 2.5 : (isDropTarget ? 2 : MacClippyDockTheme.pillBorderWidth)))
            )
            // Keep the Button label's hit shape aligned with the visible
            // capsule. Without this, SwiftUI can use the text's intrinsic
            // bounds for drag/drop hit testing and leave the pill's empty
            // horizontal padding unable to receive a drop.
            .contentShape(Capsule())
            .shadow(color: .black.opacity(selected ? 0.05 : 0), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "Selected" : "")
        // The drop modifier is attached to the Button by the pinboard row.
        // Declare the same shape at the Button level so the full visible
        // pill, not only its label, is a drop target.
        .contentShape(Capsule())
        .scaleEffect(
            reduceMotion ? 1 :
                (isDropConfirmed ? 1.08 :
                    (isDropTarget ? 1.05 : (isHovered ? MacClippyMotion.hoverScale : 1)))
        )
        .onHover { hovering in hoveredFilterPill = hovering ? title : (hoveredFilterPill == title ? nil : hoveredFilterPill) }
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
