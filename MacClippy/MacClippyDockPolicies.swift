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

/// Rail pills share `.history` for All/URL/Image. Animate the card well
/// from this identity so those switches crossfade like tab changes.
enum MacClippyDockFilterPillWashPolicy {
    static func opacity(selected: Bool, hovered: Bool) -> Double {
        if selected { return 0.22 }
        if hovered { return 0.12 }
        return 0
    }
}

enum MacClippyDockFilterSurfacePolicy {
    /// The card well keeps a fixed height and slides incoming pages from
    /// the trailing edge. Identity changes stay inside that clipped track
    /// so History ↔ Snippets cannot jump between a centered empty state
    /// and the compact card row.
    static let remountsCarouselPage = true
    static let slidesFromTrailing = true

    static func usesSlideTransition(surfaceID: String) -> Bool {
        surfaceID.hasPrefix("smart:")
    }

    static func id(tab: MacClippyDockTab, query: String) -> String {
        switch tab {
        case .snippets:
            return "snippets"
        case let .pinboard(id):
            return "pinboard:\(id.rawValue)"
        case .history:
            if let list = MacClippySmartListPolicy.catalog.first(where: {
                MacClippySmartListPolicy.isActive($0, in: query)
            }) {
                return "smart:\(list.id)"
            }
            return "history"
        }
    }
}

enum MacClippyDockModal: Equatable {
    case createCategory(token: UInt)
    case renameItem(recordID: RecordID, initialName: String?, token: UInt)
    case renameCategory(pinboardID: RecordID, token: UInt)
    case confirmDeleteCategory(pinboardID: RecordID, name: String, token: UInt)
    case confirmDeleteItems(ids: [RecordID], includesPinned: Bool, token: UInt)
    case choosePinboard(ids: [RecordID], token: UInt)
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
        isInsideStatusItem: Bool = false,
        ignoreUntil: Date,
        now: Date
    ) -> Bool {
        guard !isInsideExcludedWindow, !isInsideStatusItem else { return false }
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

enum MacClippyThumbnailRetainPolicy {
    static func shouldClearDisplayedImage(
        displayedIdentity: String?,
        loadingIdentity: String
    ) -> Bool {
        displayedIdentity != loadingIdentity
    }
}

/// Prefer the loaded pixels only while they still belong to the current
/// identity. A remount or URL change must not paint the previous file.
enum MacClippyThumbnailDisplayPolicy {
    static func displayed<Image>(
        loadedIdentity: String?,
        currentIdentity: String,
        image: Image?,
        cached: Image?
    ) -> Image? {
        if loadedIdentity == currentIdentity {
            return image ?? cached
        }
        return cached
    }
}

/// Source-app icons resolve off the main thread. A global generation bump
/// remounts every card, which is what makes Finder file cards flash while
/// Chrome URL cards stay still. Per-bundle counters keep Chrome resolve from
/// remounting Finder, and a second resolve still remounts that bundle after
/// NSCache eviction.
struct MacClippySourceResolveBatch: Equatable {
    var generations: [String: UInt] = [:]
    var pending: Set<String> = []

    mutating func enqueue(_ bundleID: String) {
        pending.insert(bundleID)
    }

    mutating func flush() {
        generations = MacClippySourceCardRefreshPolicy.incrementing(
            generations,
            resolvedBundleIDs: pending
        )
        pending = []
    }
}

enum MacClippySourceCardRefreshPolicy {
    static func snapshotGeneration(
        cardBundleID: String?,
        generations: [String: UInt]
    ) -> UInt {
        guard let cardBundleID else { return 0 }
        return generations[cardBundleID] ?? 0
    }

    static func incrementing(
        _ generations: [String: UInt],
        resolvedBundleIDs: Set<String>
    ) -> [String: UInt] {
        var next = generations
        for bundleID in resolvedBundleIDs {
            next[bundleID, default: 0] &+= 1
        }
        return next
    }

    static func resolvedBundleID(from object: Any?) -> String? {
        guard let bundleID = object as? String else { return nil }
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
