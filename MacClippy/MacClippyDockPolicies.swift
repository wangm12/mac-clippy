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

// URL detection for the URL-smart card body. Only a single, trimmed URL is
// recognized (not prose containing a URL); the full URL stays in the preview
// text and accessibility label so nothing is lost.
enum MacClippyDockURLPolicy {
    static func url(from preview: String) -> URL? {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("://") || trimmed.hasPrefix("www.") else { return nil }
        // Reject if there is whitespace inside (means it is prose, not a URL).
        guard !trimmed.contains(" ") && !trimmed.contains("\n") else { return nil }
        let candidate = trimmed.hasPrefix("www.") ? "https://\(trimmed)" : trimmed
        guard let url = URL(string: candidate), url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }
}

// Code detection for the dark-terminal card body. Conservative: a preview is
// treated as code only if it has a strong code signature (braces, semicolons,
// common keywords, leading indentation, or a shebang). Avoids misclassifying
// prose with a colon or slash.
enum MacClippyDockCodePolicy {
    static func isCode(_ preview: String) -> Bool {
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)

        // Build/linker output is multiline and flag-heavy, but it is not source
        // code. Keep it on the readable paper surface instead of turning every
        // compiler diagnostic or command log into a terminal card.
        let buildOutputMarkers = [
            "-Xlinker",
            "-install_name",
            "LinkFileList",
            ".swiftmodule",
            ".dylib"
        ]
        let markerCount = buildOutputMarkers.reduce(into: 0) { count, marker in
            if trimmed.contains(marker) { count += 1 }
        }
        if markerCount >= 2 { return false }

        // A shebang is an unambiguous code/script signal.
        if trimmed.hasPrefix("#!") { return true }
        // Curly-brace structure + semicolons => code. Parentheses and square
        // brackets are common in ordinary prompts (timestamps, shot lists,
        // and explanations), so they are not code signals on their own.
        let openBraces = trimmed.filter { $0 == "{" }.count
        let semicolons = trimmed.filter { $0 == ";" }.count
        if openBraces >= 2 || semicolons >= 2 { return true }
        // Common keyword-at-line-start signatures.
        let keywords = ["func ", "def ", "class ", "import ", "const ", "let ", "var ", "public ", "private ", "return ", "if ", "for ", "while "]
        if lines.contains(where: { line in keywords.contains { line.trimmingCharacters(in: .whitespaces).hasPrefix($0) } }) {
            return true
        }
        return false
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
    static let gap: CGFloat = 12
    static let padding: CGFloat = 16
    // Use semantic text styles so macOS accessibility font settings scale the
    // card body instead of being trapped at a fixed 13pt size.
    static let contentFont = Font.callout
    static let contentMonospacedFont = Font.system(.callout, design: .monospaced)
    // Vertical padding inside the horizontal carousel ScrollViews (applied to
    // the card row). Kept generous enough that the card border never clips
    // against the scroll view's bounds or the panel's top clip shape.
    static let carouselVerticalPadding: CGFloat = 10
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

    // Compact relative timestamp for the card header. Mirrors the reference
    // prototype's "2m / 12m / Yesterday / Tue" style so the header stays short.
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

    static func displayLabel(for relativeLabel: String) -> String {
        if relativeLabel.hasSuffix("m") || relativeLabel.hasSuffix("h") {
            return "\(relativeLabel) ago"
        }
        return relativeLabel
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
