import AppKit
import SwiftUI

// Reference cool-neutral visual language for the standalone mac-clippy dock
// surface. Light: cool white/gray panel + backdrop, crisp dark text,
// restrained gray borders. Dark: adaptive cool-neutral counterpart that keeps
// the same cool hue family. The accent follows the user-selected macOS system
// accent (NSColor.controlAccentColor). The panel uses a vibrancy material.
// Clipboard cards keep a cool-neutral base, then wash in the source app's
// extracted accent so Xcode, WeChat, and Safari read as different surfaces.
// Colors resolve at draw time so an appearance or accent change recomputes
// immediately.
@MainActor
enum MacClippyDockTheme {
    // Light palette (cool white/gray, reference-aligned).
    static let bg0 = NSColor(calibratedRed: 0.965, green: 0.969, blue: 0.973, alpha: 1)      // #f7f8fa
    static let bg1 = NSColor(calibratedRed: 0.929, green: 0.933, blue: 0.941, alpha: 1)      // #edeef1
    static let panelLight = NSColor(calibratedRed: 0.996, green: 0.996, blue: 1, alpha: 0.86)
    static let panelStrongLight = NSColor(calibratedRed: 0.992, green: 0.992, blue: 1, alpha: 0.92)
    static let cardLight = NSColor(calibratedRed: 0.985, green: 0.987, blue: 0.992, alpha: 0.78)
    static let cardHoverLight = NSColor(calibratedRed: 0.995, green: 0.996, blue: 1, alpha: 0.86)
    static let textLight = NSColor(calibratedRed: 0.110, green: 0.118, blue: 0.133, alpha: 1) // #1c1e22
    static let mutedLight = NSColor(calibratedRed: 0.392, green: 0.412, blue: 0.447, alpha: 1)
    static let muted2Light = NSColor(calibratedRed: 0.565, green: 0.588, blue: 0.624, alpha: 1)
    static let lineLight = NSColor(calibratedRed: 0.196, green: 0.220, blue: 0.259, alpha: 0.12)

    // Dark palette: same cool-neutral hue family, lifted for dark surfaces.
    static let bg0Dark = NSColor(calibratedRed: 0.059, green: 0.063, blue: 0.071, alpha: 1)
    static let bg1Dark = NSColor(calibratedRed: 0.094, green: 0.098, blue: 0.110, alpha: 1)
    static let panelDark = NSColor(calibratedRed: 0.122, green: 0.129, blue: 0.145, alpha: 0.82)
    static let panelStrongDark = NSColor(calibratedRed: 0.149, green: 0.157, blue: 0.173, alpha: 0.92)
    static let cardDark = NSColor(calibratedRed: 0.184, green: 0.192, blue: 0.208, alpha: 0.88)
    static let cardHoverDark = NSColor(calibratedRed: 0.216, green: 0.224, blue: 0.239, alpha: 0.94)
    static let textDark = NSColor(calibratedRed: 0.957, green: 0.965, blue: 0.973, alpha: 1)
    static let mutedDark = NSColor(calibratedRed: 0.765, green: 0.788, blue: 0.816, alpha: 1)
    static let muted2Dark = NSColor(calibratedRed: 0.612, green: 0.635, blue: 0.667, alpha: 1)
    static let lineDark = NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.14)

    // Accent follows the user-selected macOS system accent
    // (NSColor.controlAccentColor) so the dock adapts when the user changes
    // the accent in System Settings. Resolved at draw time so an accent or
    // appearance change recomputes immediately. accentSoft is derived from
    // the same accent at a low alpha for soft fills/rings.
    static var accent: NSColor { NSColor.controlAccentColor }
    static var accentSoft: NSColor {
        NSColor.controlAccentColor.withAlphaComponent(0.16)
    }

    static var isDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static var panel: NSColor { isDark ? panelDark : panelLight }
    static var panelStrong: NSColor { isDark ? panelStrongDark : panelStrongLight }
    static var card: NSColor { isDark ? cardDark : cardLight }
    static var cardHover: NSColor { isDark ? cardHoverDark : cardHoverLight }
    static var text: NSColor { isDark ? textDark : textLight }
    static var muted: NSColor { isDark ? mutedDark : mutedLight }
    static var muted2: NSColor { isDark ? muted2Dark : muted2Light }
    static var line: NSColor { isDark ? lineDark : lineLight }

    static var accentColor: Color { Color(nsColor: accent) }
    static var accentForegroundColor: Color {
        guard let rgb = accent.usingColorSpace(.deviceRGB) else {
            return Color(nsColor: textDark)
        }
        let brightness = (0.2126 * rgb.redComponent)
            + (0.7152 * rgb.greenComponent)
            + (0.0722 * rgb.blueComponent)
        return Color(nsColor: brightness > 0.62 ? textLight : textDark)
    }
    static var accentSoftColor: Color { Color(nsColor: accentSoft) }
    static var textColor: Color { Color(nsColor: text) }
    static var mutedColor: Color { Color(nsColor: muted) }
    static var muted2Color: Color { Color(nsColor: muted2) }
    // Lightest text tone for low-priority metadata like the below-card
    // timestamp, so the copied content stays first and the caption recedes.
    static var muted3Color: Color {
        return Color(nsColor: isDark ? muted2Dark : mutedLight)
    }
    static var lineColor: Color { Color(nsColor: line) }
    static var cardColor: Color { Color(nsColor: card) }
    static var cardHoverColor: Color { Color(nsColor: cardHover) }
    static var panelStrongColor: Color { Color(nsColor: panelStrong) }
    // Matches the AppKit dock backdrop gradient's top stop so edge fades
    // do not paint a cooler, near-white stripe over bg0/bg1.
    static var backdropColor: Color { Color(nsColor: isDark ? bg0Dark : bg0) }

    // Clipboard cards sit on the shared cool-neutral fill, then a low-alpha
    // wash from the source app's icon accent. Image cards still fill the
    // face; this tint is for text and file metadata surfaces.
    static func sourceCardBackground(
        accent: NSColor,
        elevated: Bool,
        in shape: some Shape = RoundedRectangle(
            cornerRadius: MacClippyDockCardMetrics.radius,
            style: .continuous
        )
    ) -> some View {
        shape.fill(elevated ? cardHoverColor : cardColor)
            .overlay {
                shape.fill(Color(nsColor: accent).opacity(isDark ? 0.18 : 0.12))
            }
    }

    // Snippet cards use the same stable content surface as clipboard cards.
    static func snippetCardBackground(
        elevated: Bool,
        in shape: some Shape = RoundedRectangle(
            cornerRadius: MacClippyDockCardMetrics.radius,
            style: .continuous
        )
    ) -> some View {
        let surface = elevated ? cardHoverColor : cardColor
        return shape.fill(surface)
    }

    // Unified pill/tag border tokens so every pill, icon-button, and badge
    // across the dock shares the same border thickness, color transparency,
    // and inset method. This prevents drift: all interactive surfaces use a
    // 1pt stroke inset by 0.5pt so the border stays inside the shape and is
    // never clipped.
    static let pillBorderWidth: CGFloat = 1
    static let pillBorderInset: CGFloat = 0.5
    // Resting border for pills/tags.
    static var pillRestBorder: Color { lineColor }
    // Hover/focus border for pills/tags — one shared accent transparency.
    static var pillHoverBorder: Color { accentColor.opacity(0.4) }
    // Strong border for active/selected/drop-target states.
    static var pillActiveBorder: Color { accentColor.opacity(0.6) }

    static var contentTextColor: Color { textColor }
    static var contentMutedColor: Color { mutedColor }
}

// Shared pill/tag border modifier so every capsule/circle pill across the dock
// gets the exact same border thickness, inset, and color tokens — no drift
// between filter pills, +New, gear, badges, or the feedback toast.
extension View {
    func pillBorder(_ color: Color) -> some View {
        overlay(
            Capsule()
                .inset(by: MacClippyDockTheme.pillBorderInset)
                .stroke(color, lineWidth: MacClippyDockTheme.pillBorderWidth)
        )
    }

    func circleBorder(_ color: Color) -> some View {
        overlay(
            Circle()
                .inset(by: MacClippyDockTheme.pillBorderInset)
                .stroke(color, lineWidth: MacClippyDockTheme.pillBorderWidth)
        )
    }

    // Staggered fade-in for action bar buttons. Each button fades/slides in
    // with a tiny per-index delay (left-to-right) so the bar feels orchestrated
    // instead of a single block pop. Driven by the parent's `appeared` flag so
    // it runs once when the bar first appears, not on every re-render.
    func staggeredAppearance(index: Int, appeared: Bool, reduceMotion: Bool) -> some View {
        opacity(reduceMotion ? 1 : (appeared ? 1 : 0))
            .offset(y: reduceMotion ? 0 : (appeared ? 0 : 6))
            .animation(
                reduceMotion ? nil :
                .easeOut(duration: MacClippyMotion.actionBarStaggerDuration)
                    .delay(Double(index) * MacClippyMotion.actionBarStaggerStep),
                value: appeared
            )
    }
}
