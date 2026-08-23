import AppKit
import SwiftUI

enum MacClippyConcentricRadius {
    static let minimum: CGFloat = 8

    static func inner(outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(minimum, outer - inset)
    }
}

enum MacClippyDockGlassStyle {
    static let regularName = "regular"
}

enum MacClippyDockBackdropHolePolicy {
    static let railHeight: CGFloat = 48
    static let topInset: CGFloat = 12
    static let panelCornerRadius: CGFloat = 28

    static var punchedHoleHeight: CGFloat {
        topInset + railHeight
    }

    static func shouldPunchHole(reduceTransparency: Bool) -> Bool {
        !reduceTransparency
    }
}

enum MacClippySettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general
    case privacy
    case permissions
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .privacy: "Privacy"
        case .permissions: "Permissions"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .privacy: "hand.raised"
        case .permissions: "lock.shield"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

enum MacClippyChromeShape {
    static func topBar(radius: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: radius,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: radius,
            style: .continuous
        )
    }

    static func bottomBar(radius: CGFloat) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous
        )
    }
}

enum MacClippySettingsMetrics {
    static let sidebarIdealWidth: CGFloat = 216
    static let historyPickerWidth: CGFloat = 310
    static let minWidth: CGFloat = 720
    static let minHeight: CGFloat = 520
    static let idealWidth: CGFloat = 880
    static let idealHeight: CGFloat = 760

    static var minSize: NSSize {
        NSSize(width: minWidth, height: minHeight)
    }
}

struct MacClippyGlassContainer<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

extension View {
    @ViewBuilder
    func macClippyFloatingGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self.glassEffect(.regular, in: shape)
            }
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func macClippySearchGlass() -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(
                .regular.interactive(),
                in: .rect(
                    corners: .concentric(minimum: .fixed(MacClippyConcentricRadius.minimum)),
                    isUniform: true
                )
            )
        } else {
            self.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        }
    }

    @ViewBuilder
    func macClippyGlassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    func macClippyGlassProminentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    func macClippyChromeButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self.buttonStyle(.plain)
        }
    }

    // Filter chips stay Regular glass. Selection and hover are overlay
    // washes so the glass recipe never changes. `.interactive()` press
    // plus a tinted recipe each flashed the chip on click.
    @ViewBuilder
    func macClippyFilterChipStyle(selected: Bool, hovered: Bool = false, tint: Color) -> some View {
        let wash = tint.opacity(selected ? 0.22 : (hovered ? 0.12 : 0))
        if #available(macOS 26, *) {
            self
                .buttonStyle(.plain)
                .background(wash, in: Capsule())
                .glassEffect(.regular, in: .capsule)
        } else {
            self
                .buttonStyle(.plain)
                .background(wash, in: Capsule())
        }
    }

    @ViewBuilder
    func macClippyGlassEffectID<ID: Hashable & Sendable>(
        _ id: ID,
        in namespace: Namespace.ID,
        enabled: Bool
    ) -> some View {
        if #available(macOS 26, *), enabled {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    @ViewBuilder
    func macClippyNavContainerShape() -> some View {
        if #available(macOS 26, *) {
            self.containerShape(
                RoundedRectangle(
                    cornerRadius: MacClippyDockBackdropHolePolicy.panelCornerRadius,
                    style: .continuous
                )
            )
        } else {
            self
        }
    }
}
