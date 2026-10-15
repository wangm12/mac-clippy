import AppKit
import SwiftUI
import UniformTypeIdentifiers

import MacClippyCore

struct MacClippyDockChromeIconButton: View {
    let systemImage: String
    let glassID: String
    let namespace: Namespace.ID
    let reduceMotion: Bool
    let highContrast: Bool
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let help: String
    let action: () -> Void
    var selected = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 36, height: 36)
                // The hit shape belongs to the label. Putting it outside the
                // Button only decorates the chrome and leaves its edges inert.
                .contentShape(Circle())
        }
        .modifier(MacClippyDockChromeIconStyle(
            glassID: glassID, namespace: namespace, reduceMotion: reduceMotion,
            highContrast: highContrast, selected: selected, showsPressFeedback: true))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
        .help(help)
    }
}

struct MacClippyDockChromeIconMenu<Content: View>: View {
    let systemImage: String
    let glassID: String
    let namespace: Namespace.ID
    let reduceMotion: Bool
    let highContrast: Bool
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let help: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemImage)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .modifier(MacClippyDockChromeIconStyle(
            glassID: glassID, namespace: namespace, reduceMotion: reduceMotion,
            highContrast: highContrast))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
        .help(help)
    }
}

private struct MacClippyDockChromeIconStyle: ViewModifier {
    let glassID: String
    let namespace: Namespace.ID
    let reduceMotion: Bool
    let highContrast: Bool
    var selected = false
    var showsPressFeedback = false

    @State private var isHovered = false

    func body(content: Content) -> some View {
        let ringWidth: CGFloat = highContrast ? 2 : MacClippyDockTheme.pillBorderWidth
        let ringColor = isHovered
            ? MacClippyDockTheme.interactiveFocusBorder
            : MacClippyDockTheme.pillRestBorder
        return content
        .font(.body.weight(.semibold))
        .foregroundStyle(isHovered || selected ? MacClippyDockTheme.accentColor : MacClippyDockTheme.textColor)
        .frame(width: 36, height: 36)
        .macClippyGlassEffectID(glassID, in: namespace, enabled: !reduceMotion)
        .macClippyFilterChipStyle(
            selected: selected,
            hovered: isHovered,
            tint: MacClippyDockTheme.accentColor,
            pressFeedback: showsPressFeedback
        )
        .overlay(
            Capsule()
                .inset(by: MacClippyDockTheme.pillBorderInset)
                .stroke(ringColor, lineWidth: ringWidth)
        )
        .contentShape(Capsule())
        .animation(nil, value: isHovered)
        .onContinuousHover { phase in
            isHovered = MacClippyDockHoverPolicy.isHovering(phase)
        }
    }
}

struct MacClippyDockFilterPill: View {
    let title: String
    let selected: Bool
    var systemImage: String?
    var isDropTarget = false
    var isDropConfirmed = false
    var accentHex: String?
    let reduceMotion: Bool
    let highContrast: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let accentColor = accentHex.map { Color(macClippyHex: $0) }
        let ringWidth: CGFloat = highContrast ? 2 :
            (isDropConfirmed ? 2.5 : (isDropTarget ? 2 : MacClippyDockTheme.pillBorderWidth))
        let ringColor = isDropConfirmed ? (accentColor ?? MacClippyDockTheme.accentColor) :
            (isDropTarget ? MacClippyDockTheme.interactiveStrongBorder :
                (isHovered ? MacClippyDockTheme.interactiveFocusBorder : MacClippyDockTheme.pillRestBorder))
        return Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            accentColor ?? (isHovered ? MacClippyDockTheme.accentColor : MacClippyDockTheme.textColor)
                        )
                } else if let accentColor {
                    Circle()
                        .fill(accentColor)
                        .frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(
                isHovered ? MacClippyDockTheme.accentColor : MacClippyDockTheme.textColor
            )
            .padding(.horizontal, 14)
            .frame(height: 36)
            .contentShape(Capsule())
        }
        .macClippyFilterChipStyle(
            selected: selected || isDropConfirmed || isDropTarget,
            hovered: isHovered,
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
        .animation(
            MacClippyMotion.animation(MacClippyMotion.hoverAnimation, reduceMotion: reduceMotion),
            value: isDropTarget
        )
        .animation(
            MacClippyMotion.animation(MacClippyMotion.hoverAnimation, reduceMotion: reduceMotion),
            value: isDropConfirmed
        )
        .animation(nil, value: selected)
        .animation(nil, value: isHovered)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
        .onContinuousHover { phase in
            isHovered = MacClippyDockHoverPolicy.isHovering(phase)
        }
    }
}

extension MacClippyDockView {
    var allFilterPill: some View {
        filterPill(
            title: "All",
            selected: model.isAllFilterSelected
        ) {
            model.selectAllFilter()
        }
    }

    var defaultFilterPillsOnly: some View {
        HStack(spacing: 6) {
            ForEach(model.visibleSmartLists) { list in
                filterPill(
                    title: list.title,
                    selected: MacClippySmartListPolicy.isActive(list, in: model.query),
                    systemImage: list.systemImage
                ) {
                    model.toggleSmartList(list)
                }
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        model.hideSmartList(list)
                    }
                }
            }
            filterPill(
                title: "Snippets",
                selected: model.selectedTab == .snippets,
                systemImage: "text.quote",
                isDropTarget: dropTargetSnippets,
                isDropConfirmed: dropConfirmedSnippets
            ) {
                model.selectSnippetsFilter()
            }
            .onDrop(
                of: clipboardRecordDragTypes,
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

    func defaultFilterPillsContainer(maxWidth: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            defaultFilterPillsOnly
            ScrollView(.horizontal, showsIndicators: false) {
                defaultFilterPillsOnly
            }
            .frame(maxWidth: maxWidth)
        }
    }

    var userCategoryPillsOnly: some View {
        HStack(spacing: 6) {
            ForEach(model.pinboards) { pinboard in
                filterPill(
                    title: pinboard.name,
                    selected: model.selectedTab == .pinboard(pinboard.id),
                    systemImage: "pin.fill",
                    isDropTarget: dropTargetPinboardID == pinboard.id,
                    isDropConfirmed: dropConfirmedPinboardID == pinboard.id,
                    accentHex: pinboard.colorHex
                ) {
                    model.selectTab(.pinboard(pinboard.id))
                }
                .contextMenu { pinboardContextMenu(pinboard) }
                .onDrop(
                    of: clipboardRecordDragTypes,
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
            newCategoryButton
        }
    }

    func userCategoryPillsContainer(maxWidth: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            userCategoryPillsOnly
            ScrollView(.horizontal, showsIndicators: false) {
                userCategoryPillsOnly
            }
            .frame(maxWidth: maxWidth)
        }
    }

    var filterPillsOnly: some View {
        HStack(spacing: 6) {
            allFilterPill
            defaultFilterPillsOnly
            userCategoryPillsOnly
        }
    }

    func filterPillsContainer(maxWidth: CGFloat) -> some View {
        ViewThatFits(in: .horizontal) {
            filterPillsOnly
            ScrollView(.horizontal, showsIndicators: false) {
                filterPillsOnly
            }
            .frame(maxWidth: maxWidth)
        }
    }

    var settingsButton: some View {
        MacClippyDockChromeIconButton(
            systemImage: "gearshape",
            glassID: "gear",
            namespace: headerGlassNamespace,
            reduceMotion: reduceMotion,
            highContrast: highContrast,
            accessibilityLabel: "Settings",
            accessibilityIdentifier: "macClippy.settingsButton",
            help: "Settings"
        ) {
            showAboutPanel()
        }
    }

    var headerTrailingButtons: some View {
        settingsButton
    }

    var filterPillRow: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                filterPillsOnly
            }
            headerTrailingButtons
        }
    }

    // Keep the historical helper name to avoid changing the dock's call site.
    func showAboutPanel() {
        onOpenSettings()
    }

    // +New as a standalone icon button, separated from the filter pills so
    // the tab row stays semantically pure (filters only). Instant hover.
    var newCategoryButton: some View {
        MacClippyDockChromeIconButton(
            systemImage: "plus",
            glassID: "newCategory",
            namespace: headerGlassNamespace,
            reduceMotion: reduceMotion,
            highContrast: highContrast,
            accessibilityLabel: "Add Pinboard",
            accessibilityIdentifier: "macClippy.createCategoryButton",
            help: "Add Pinboard"
        ) {
            model.presentCreateCategory()
        }
    }

    func filterPill(
        title: String,
        selected: Bool,
        systemImage: String? = nil,
        isDropTarget: Bool = false,
        isDropConfirmed: Bool = false,
        accentHex: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        MacClippyDockFilterPill(
            title: title,
            selected: selected,
            systemImage: systemImage,
            isDropTarget: isDropTarget,
            isDropConfirmed: isDropConfirmed,
            accentHex: accentHex,
            reduceMotion: reduceMotion,
            highContrast: highContrast,
            action: action
        )
    }

    var clipboardRecordDragType: UTType {
        UTType(exportedAs: MacClippyCardDragPolicy.recordTypeIdentifier, conformingTo: .data)
    }

    var clipboardRecordDragTypes: [UTType] {
        var types: [UTType] = [clipboardRecordDragType]
        if let type = UTType(MacClippyCardDragPolicy.recordTypeIdentifier), !types.contains(type) {
            types.append(type)
        }
        return types
    }
}
