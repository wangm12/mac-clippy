import SwiftUI

import MacClippyCore

extension MacClippyDockCardMetrics {
    static func height(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let extra: CGFloat
        switch dynamicTypeSize {
        case .xSmall, .small, .medium, .large:
            extra = 0
        case .xLarge:
            extra = 12
        case .xxLarge:
            extra = 24
        case .xxxLarge:
            extra = 36
        case .accessibility1:
            extra = 52
        case .accessibility2:
            extra = 68
        case .accessibility3:
            extra = 84
        case .accessibility4:
            extra = 100
        case .accessibility5:
            extra = 116
        @unknown default:
            extra = 0
        }
        return height + extra
    }

    static func carouselHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        height(for: dynamicTypeSize) + carouselVerticalPadding * 2
    }
}

enum MacClippyDockEmptyStateCopy {
    static func title(
        hasQuery: Bool,
        isPinboard: Bool,
        pinboardName: String?,
        conflictingTypes: Bool = false
    ) -> String {
        if hasQuery && conflictingTypes { return "Incompatible type filters" }
        if hasQuery { return "No matches" }
        if isPinboard {
            return pinboardName.map { "\($0) is empty" } ?? "Pinboard is empty"
        }
        return "No clipboard history yet"
    }

    static func subtitle(
        hasQuery: Bool,
        isPinboard: Bool,
        conflictingTypes: Bool = false
    ) -> String {
        if hasQuery && conflictingTypes {
            return "Remove extra type: filters and search again."
        }
        if hasQuery { return "Try a different search." }
        if isPinboard { return "Pinned items will appear here." }
        return "Copied items will appear here."
    }

    static func title(
        query: String,
        tab: MacClippyDockTab,
        pinboardName: String?
    ) -> String {
        title(
            hasQuery: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isPinboard: isPinboard(tab),
            pinboardName: pinboardName,
            conflictingTypes: MacClippySearchGrammar.parse(query).hasConflictingContentTypes
        )
    }

    static func subtitle(query: String, tab: MacClippyDockTab) -> String {
        subtitle(
            hasQuery: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            isPinboard: isPinboard(tab),
            conflictingTypes: MacClippySearchGrammar.parse(query).hasConflictingContentTypes
        )
    }

    private static func isPinboard(_ tab: MacClippyDockTab) -> Bool {
        if case .pinboard = tab { return true }
        return false
    }
}
