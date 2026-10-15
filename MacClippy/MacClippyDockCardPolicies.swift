import AppKit
import Foundation
import SwiftUI

import MacClippyCore
import MacClippyPlatform

enum MacClippyDockCardMetrics {
    // Compact card size restored to the prior vertical height. Cards stay
    // fixed-size and the carousel scrolls horizontally; the metrics are the
    // single source of truth for card width/height/gap/padding/radius so the
    // carousel and the per-card frames stay in sync.
    static let width: CGFloat = 248
    // Compact card body that still leaves room for URL and code previews.
    static let height: CGFloat = 220
    static let radius: CGFloat = 22
    static let gap: CGFloat = 32
    static let padding: CGFloat = 24
    // Image cards keep a framed preview, not an edge-to-edge crop. The
    // inset lets the tinted face read around the photo so a tall screenshot
    // is recognizable at a glance.
    static let imageInset: CGFloat = 16
    static let imagePreviewRadius: CGFloat = 12
    // Use semantic text styles so macOS accessibility font settings scale the
    // card body instead of being trapped at a fixed 13pt size.
    static let contentFont = Font.body.weight(.medium)
    static let contentMonospacedFont = Font.system(.body, design: .monospaced).weight(.medium)
    // Vertical padding inside the horizontal carousel ScrollViews (applied to
    // the card row). Kept generous enough that the card border never clips
    // against the scroll view's bounds or the panel's top clip shape.
    static let carouselVerticalPadding: CGFloat = 16
    // Below-card relative timestamp. Kept outside the rounded face so the
    // card itself stays content-only, matching the reference caption.
    static let captionSpacing: CGFloat = 16
    static let captionHeight: CGFloat = 22
    // Native app icon sits on the card corner, half outside the rounded
    // face. It must not be drawn inside the clipped card content.
    static let sourceBadgeSize: CGFloat = 48
    static let sourceBadgeOverlap: CGFloat = 20
}

/// Image and file cards must show a name on the face. Finder copies use the
/// filename; clipboard images fall back to a stable "Image" label so a photo
/// is never an unlabeled thumbnail.
/// Text-like cards keep the clipboard body on the face. A custom name is a
/// tag above that body so rename is visible without hiding the original text.
enum MacClippyDockCardNameTagPolicy {
    static let maximumLines = 2
    static let font = Font.callout.weight(.semibold)
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 6
    static let cornerRadius: CGFloat = 8

    static func text(for item: MacClippyHistoryEntry) -> String? {
        switch item.contentKind {
        case .text, .html, .rtf:
            return item.customLabel
        case .image, .files:
            return nil
        }
    }
}

enum MacClippyDockCardVisibleNamePolicy {
    static func text(for item: MacClippyHistoryEntry) -> String {
        if let customLabel = item.customLabel, !customLabel.isEmpty {
            return customLabel
        }
        switch item.contentKind {
        case .files:
            guard let first = item.fileURLs.first else { return "Files" }
            let name = MacClippyFilePresentation.displayName(for: first)
            if item.fileURLs.count <= 1 {
                return name.isEmpty ? "Files" : name
            }
            return name.isEmpty
                ? MacClippyFilePresentation.title(fileCount: item.fileURLs.count)
                : "\(name) + \(item.fileURLs.count - 1)"
        case .image:
            if let dimensions = item.typeMetadataSubtitle, !dimensions.isEmpty {
                return "Image · \(dimensions)"
            }
            return "Image"
        case .text, .html, .rtf:
            return item.displayTitle
        }
    }
}

enum MacClippyDockCardBorderPolicy {
    static func usesAccent(isActive: Bool, isHovered: Bool) -> Bool {
        isActive || isHovered
    }

    @MainActor
    static func color(isActive: Bool, isHovered: Bool) -> Color {
        if isActive {
            return MacClippyDockTheme.interactiveFocusBorder
        }
        if isHovered {
            return MacClippyDockTheme.interactiveHoverBorder
        }
        return MacClippyDockTheme.interactiveRestBorder
    }

    static func lineWidth(isActive: Bool, highContrast: Bool) -> CGFloat {
        if highContrast {
            return isActive ? 2.5 : 1.5
        }
        return isActive ? 2 : 1
    }
}

enum MacClippyDockHoverPolicy {
    // Leave always updates hover. Swallowing mouseDown exits left pills
    // and cards stuck in the accent tint after the pointer moved away.
    static func shouldApplyHover(_ hovering: Bool, pressedMouseButtons: Int) -> Bool {
        _ = hovering
        _ = pressedMouseButtons
        return true
    }

    static func isHovering(_ phase: HoverPhase) -> Bool {
        if case .active = phase {
            return true
        }
        return false
    }
}

enum MacClippyDockCardHoverChrome {
    static func allowsHoverScale(isScrolling: Bool, reduceMotion: Bool) -> Bool {
        !isScrolling && !reduceMotion
    }

    static func shadowOpacity(elevated: Bool, hovered: Bool, isScrolling: Bool = false) -> Double {
        if isScrolling { return 0.04 }
        switch (elevated, hovered) {
        case (true, true): return 0.18
        case (true, false): return 0.16
        case (false, true): return 0.13
        case (false, false): return 0.08
        }
    }

    static func shadowRadius(elevated: Bool, hovered: Bool, isScrolling: Bool = false) -> CGFloat {
        if isScrolling { return 4 }
        switch (elevated, hovered) {
        case (true, true): return 15
        case (true, false): return 14
        case (false, true): return 13
        case (false, false): return 10
        }
    }

    static func shadowY(elevated: Bool, hovered: Bool, isScrolling: Bool = false) -> CGFloat {
        if isScrolling { return 1 }
        return elevated ? 5 : (hovered ? 4 : 3)
    }
}

struct MacClippyDockCategoryPresentation: Identifiable, Equatable, Sendable {
    let id: RecordID
    let name: String
    let colorHex: String
}

enum MacClippyDockCardRemoteClipboardPolicy {
    static let symbolName = "iphone"
    static let help = "Copied from another Apple device"
    static let accessibilityPhrase = "from another Apple device"
}

enum MacClippyDockCardCategoryPolicy {
    static let visibleCategoryLimit = 2

    static func shouldShowIndicator(
        categories: [MacClippyDockCategoryPresentation],
        selectedTab: MacClippyDockTab
    ) -> Bool {
        selectedTab == .history && !categories.isEmpty
    }

    static func visibleCategories(
        from categories: [MacClippyDockCategoryPresentation]
    ) -> [MacClippyDockCategoryPresentation] {
        Array(categories.prefix(visibleCategoryLimit))
    }

    static func overflowCount(
        for categories: [MacClippyDockCategoryPresentation]
    ) -> Int {
        max(0, categories.count - visibleCategoryLimit)
    }

    static func accessibilitySummary(
        for categories: [MacClippyDockCategoryPresentation]
    ) -> String? {
        guard !categories.isEmpty else { return nil }
        return "Categories: " + categories.map(\.name).joined(separator: ", ")
    }
}
