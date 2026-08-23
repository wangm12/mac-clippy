import AppKit
import Foundation
import SwiftUI

import MacClippyCore
import MacClippyPlatform

enum MacClippyDockTab: Hashable, Sendable {
    case history
    case snippets
    case pinboard(RecordID)
}

enum MacClippyDockModal: Equatable {
    case createCategory(token: UInt)
    case renameItem(recordID: RecordID, initialName: String?, token: UInt)
    case renameCategory(pinboardID: RecordID, token: UInt)
    case confirmDeleteCategory(pinboardID: RecordID, name: String, token: UInt)
}

enum MacClippyDockPreviewTarget: Equatable, Sendable {
    case item(RecordID)
    case snippet(RecordID)

    var recordID: RecordID {
        switch self {
        case let .item(id), let .snippet(id): id
        }
    }
}

enum MacClippyDockCardHighlightPolicy {
    static func isActive(isFocused: Bool, isSelected: Bool, isPreviewVisible: Bool) -> Bool {
        isPreviewVisible ? isFocused : isSelected
    }
}

enum MacClippyDockOutsideClickPolicy {
    static func shouldDismiss(
        panelFrame: CGRect,
        clickLocation: CGPoint,
        isInsideExcludedWindow: Bool,
        ignoreUntil: Date,
        now: Date
    ) -> Bool {
        guard !isInsideExcludedWindow else { return false }
        return MacClippyDockLifecyclePolicy.shouldDismissForOutsideClick(
            panelFrame: panelFrame,
            clickLocation: clickLocation,
            ignoreUntil: ignoreUntil,
            now: now
        )
    }
}

enum MacClippyDockCategoryRailPolicy {
    static func countLabel(for count: Int) -> String? {
        count > 0 ? "\(count)" : nil
    }
}

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
    // AppKit sends hover-exit on mouseDown and hover-enter on mouseUp.
    // Applying that flicker while a tag click also changes `selected`
    // restarts the header's inherited animation and flashes the tint twice.
    static func shouldApplyHover(_ hovering: Bool, pressedMouseButtons: Int) -> Bool {
        hovering || pressedMouseButtons == 0
    }
}

enum MacClippyDockCardHoverChrome {
    static func shadowOpacity(elevated: Bool, hovered: Bool) -> Double {
        switch (elevated, hovered) {
        case (true, true): 0.18
        case (true, false): 0.16
        case (false, true): 0.13
        case (false, false): 0.08
        }
    }

    static func shadowRadius(elevated: Bool, hovered: Bool) -> CGFloat {
        switch (elevated, hovered) {
        case (true, true): 15
        case (true, false): 14
        case (false, true): 13
        case (false, false): 10
        }
    }

    static func shadowY(elevated: Bool, hovered: Bool) -> CGFloat {
        elevated ? 5 : (hovered ? 4 : 3)
    }
}

struct MacClippyDockCategoryPresentation: Identifiable, Equatable, Sendable {
    let id: RecordID
    let name: String
    let colorHex: String
}

enum MacClippyDockCardCategoryPolicy {
    static let visibleCategoryLimit = 2

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

enum MacClippyDockTimestampPolicy {
    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    // Compact relative timestamp for dense chrome such as the preview
    // header. Card captions use `captionLabel` instead.
    static func relativeLabel(for date: Date, now: Date = Date()) -> String? {
        let interval = now.timeIntervalSince(date)
        if interval < 0 { return nil }
        let minute: TimeInterval = 60
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86400
        if interval < hour {
            let minutes = Int(interval / minute)
            return max(minutes, 1) == 1 ? "1m" : "\(max(minutes, 1))m"
        }
        if interval < day {
            let hours = Int(interval / hour)
            return "\(hours)h"
        }
        return calendarOrDateLabel(for: date, interval: interval, day: day)
    }

    // Long relative timestamp for the below-card caption:
    // "2 minutes ago" / "1 hour ago" / Yesterday / weekday / short date.
    static func captionLabel(for date: Date, now: Date = Date()) -> String? {
        let interval = now.timeIntervalSince(date)
        if interval < 0 { return nil }
        let minute: TimeInterval = 60
        let hour: TimeInterval = 3600
        let day: TimeInterval = 86400
        if interval < hour {
            let minutes = max(Int(interval / minute), 1)
            return minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        }
        if interval < day {
            let hours = max(Int(interval / hour), 1)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        return calendarOrDateLabel(for: date, interval: interval, day: day)
    }

    static func displayLabel(for relativeLabel: String) -> String {
        if relativeLabel.hasSuffix("m") || relativeLabel.hasSuffix("h") {
            return "\(relativeLabel) ago"
        }
        return relativeLabel
    }

    private static func calendarOrDateLabel(
        for date: Date,
        interval: TimeInterval,
        day: TimeInterval
    ) -> String? {
        if interval < day * 2 {
            return "Yesterday"
        }
        if interval < day * 7 {
            let weekdayIndex = Calendar.current.component(.weekday, from: date)
            let symbols = Calendar.current.shortWeekdaySymbols
            return symbols.indices.contains(weekdayIndex - 1) ? symbols[weekdayIndex - 1] : nil
        }
        return shortDateFormatter.string(from: date)
    }
}

enum MacClippyDockActionFeedback: Equatable {
    case copied(plain: Bool)
    case pasted(manual: Bool)
    case pinChanged(boardName: String, isPinned: Bool)
    case pinnedTo(boardName: String)
    case snippetCreated
    case deleted
    // P1 transient feedback for a mixed multi-paste that was NOT injected
    // because the selection contained at least one non-text-compatible record.
    // supportedCount/unsupportedCount name exactly what was not pasted so
    // nothing is silently dropped.
    case multiPasteMixed(supportedCount: Int, unsupportedCount: Int, unsupportedKinds: [MacClippyDockMultiPastePolicy.Kind])
    // P1 transient feedback for a multi-paste that was NOT injected because at
    // least one text-compatible record (text/html/rtf) had an unavailable or
    // undecodable plain-text payload (e.g. malformed RTF). availableCount
    // decoded (possibly to "") and unavailableCount did not; the unavailable
    // kinds name exactly which records could not be pasted. No paste occurred
    // so a nil payload is never silently merged as an empty piece.
    case multiPasteUnavailable(availableCount: Int, unavailableCount: Int, unavailableKinds: [MacClippyDockMultiPastePolicy.Kind])
    // P1 transient feedback for a batch delete/pin that partially succeeded:
    // some IDs were not found. succeeded is the count that acted, unsupported
    // is the count that were missing.
    case batchPartial(succeeded: Int, unsupported: Int)
    // P2a transient feedback for a rename. cleared is true when the name was
    // blanked (set to nil), false when a non-empty name was saved.
    case nameSaved(cleared: Bool)
    // Transformed copy/paste feedback. Mirrors .copied / .pasted(manual:) but
    // names the transform that was applied so the user can tell a transformed
    // result apart from a plain copy/paste. manual is true when the paste
    // required a manual Cmd+V (Accessibility unavailable), matching .pasted.
    case transformedCopied(name: String)
    case transformedPasted(name: String, manual: Bool)
    // Mixed-content sequential queue paste feedback. Distinct from Paste all
    // (which merges homogeneous text into one paste): Queue paste injects a
    // separate Cmd+V per record in visual order so mixed selections can each
    // be consumed by the target app. Full success closes the dock via the
    // existing completion; partial/manual outcomes keep the dock open so the
    // explicit result is visible.
    //
    // .queuePasteCompleted is full success: every selected record was either
    // injected or explicitly unavailable, and no manual-paste stop occurred.
    // injectedCount records were actually pasted (frequency bumped).
    // unavailableCount records were missing/malformed and reported explicitly;
    // when unavailableCount is 0 this is a clean full success.
    case queuePasteCompleted(injectedCount: Int, unavailableCount: Int)
    // .queuePastePartial is partial completion: some records were injected and
    // some were unavailable, but the queue finished without a manual stop. The
    // dock stays open so the user can see exactly what was not pasted.
    case queuePastePartial(injectedCount: Int, unavailableCount: Int, unavailableKinds: [MacClippyDockMultiPastePolicy.Kind])
    // .queuePasteManualStop is a manual-paste stop: the injector returned
    // manualPasteRequired for the current record, so the queue stopped without
    // claiming the current or any remaining ID injected. remainingCount is the
    // current ID plus every not-yet-attempted ID. The dock stays open so the
    // user can see the unconsumed IDs.
    case queuePasteManualStop(injectedCount: Int, remainingCount: Int)

    var title: String {
        switch self {
        case let .copied(plain): plain ? "Copied plain" : "Copied"
        case let .pasted(manual): manual ? "Paste manually" : "Pasted"
        case let .pinChanged(boardName, isPinned): isPinned ? "Pinned to \(boardName)" : "Unpinned"
        case let .pinnedTo(boardName): "Pinned to \(boardName)"
        case .snippetCreated: "Snippet saved"
        case .deleted: "Deleted"
        case let .multiPasteMixed(supportedCount, unsupportedCount, _):
            "\(unsupportedCount) of \(supportedCount + unsupportedCount) unsupported"
        case let .multiPasteUnavailable(availableCount, unavailableCount, _):
            "\(unavailableCount) of \(availableCount + unavailableCount) undecodable"
        case let .batchPartial(succeeded, unsupported):
            "\(succeeded) done, \(unsupported) not found"
        case let .nameSaved(cleared): cleared ? "Name cleared" : "Name saved"
        case let .transformedCopied(name): "Copied \(name)"
        case let .transformedPasted(name, manual): manual ? "Paste manually" : "Pasted \(name)"
        case let .queuePasteCompleted(injectedCount, unavailableCount):
            unavailableCount == 0 ? "Queued \(injectedCount)" : "Queued \(injectedCount), \(unavailableCount) unavailable"
        case let .queuePastePartial(injectedCount, unavailableCount, _):
            "Queued \(injectedCount), \(unavailableCount) unavailable"
        case let .queuePasteManualStop(injectedCount, remainingCount):
            "Queued \(injectedCount), \(remainingCount) need manual paste"
        }
    }

    var systemImage: String {
        switch self {
        case .copied, .pasted, .pinChanged, .pinnedTo, .snippetCreated, .deleted, .nameSaved,
             .transformedCopied, .transformedPasted,
             .queuePasteCompleted:
            "checkmark.circle.fill"
        case .multiPasteMixed, .multiPasteUnavailable, .batchPartial,
             .queuePastePartial, .queuePasteManualStop:
            "exclamationmark.triangle.fill"
        }
    }

    // True for copy-style feedback that should surface as a screen-level toast
    // instead of the in-panel overlay (mirrors paste's on-screen indicator).
    var isCopyFeedback: Bool {
        switch self {
        case .copied, .transformedCopied:
            true
        default:
            false
        }
    }
}

enum MacClippyDockPinAction: Equatable {
    case pin(boardName: String)
    case unpin(boardName: String)

    var title: String {
        switch self {
        case let .pin(boardName): "Pin to \(boardName)"
        case .unpin: "Unpin"
        }
    }
}

enum MacClippyDockPinResolver {
    static func action(
        for itemID: RecordID,
        selectedTab: MacClippyDockTab,
        pinboards: [MacClippyPinboardEntry]
    ) -> MacClippyDockPinAction? {
        let preferredID: RecordID?
        if case let .pinboard(id) = selectedTab {
            preferredID = id
        } else {
            preferredID = nil
        }

        if let preferredID,
           let preferred = pinboards.first(where: { $0.id == preferredID }),
           preferred.board.itemIDs.contains(itemID) {
            return .unpin(boardName: preferred.name)
        }
        if let containing = pinboards.first(where: { $0.board.itemIDs.contains(itemID) }) {
            return .unpin(boardName: containing.name)
        }
        guard let defaultBoard = pinboards.first else { return nil }
        return .pin(boardName: defaultBoard.name)
    }
}
