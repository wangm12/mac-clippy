import AppKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

import MacClippyCore
import MacClippyPlatform

private enum MacClippyThumbnailDownsampler {
    static func data(_ data: Data, maxPixelSize: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

enum MacClippyDockTab: Hashable, Sendable {
    case history
    case snippets
    case pinboard(RecordID)
}

enum MacClippyDockModal: Equatable {
    case createCategory(token: UInt)
    case editLabel(recordID: RecordID, initialLabel: String?, token: UInt)
    case renameCategory(pinboardID: RecordID, token: UInt)
    case confirmDeleteCategory(pinboardID: RecordID, name: String, token: UInt)
}

enum MacClippyDockPreviewTarget: Equatable, Sendable {
    case item(RecordID)
    case snippet(RecordID)
}

enum MacClippyDockCardClickIntent: Equatable {
    case focus
    case copy
}

enum MacClippyDockCardClickPolicy {
    static func intent(for clickCount: Int) -> MacClippyDockCardClickIntent {
        clickCount >= 2 ? .copy : .focus
    }
}

enum MacClippyDockCardHighlightPolicy {
    static func isActive(isFocused: Bool, isSelected: Bool, isPreviewVisible: Bool) -> Bool {
        isPreviewVisible ? isFocused : isSelected
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

// Reference cool-neutral visual language for the standalone mac-clippy dock
// surface. Light: cool white/gray panel + backdrop, crisp dark text,
// restrained gray borders. Dark: adaptive cool-neutral counterpart that keeps
// the same cool hue family. The accent follows the user-selected macOS system
// accent (NSColor.controlAccentColor). The panel uses a vibrancy material and
// clipboard cards use one stable neutral surface. Colors resolve at draw time
// so an appearance or accent change recomputes immediately. Cards use no
// gradients or source-tinted surfaces; source-app identity is carried by the
// icon block and small accents.
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
    static var accentSoftColor: Color { Color(nsColor: accentSoft) }
    static var textColor: Color { Color(nsColor: text) }
    static var mutedColor: Color { Color(nsColor: muted) }
    static var muted2Color: Color { Color(nsColor: muted2) }
    // Lightest text tone for low-priority metadata like timestamps, so the
    // header reads as source-name-first hierarchy and the timestamp recedes.
    static var muted3Color: Color { Color(nsColor: isDark ? muted2Dark : NSColor(calibratedRed: 0.597, green: 0.638, blue: 0.702, alpha: 1)) }
    static var lineColor: Color { Color(nsColor: line) }
    static var cardColor: Color { Color(nsColor: card) }
    static var cardHoverColor: Color { Color(nsColor: cardHover) }
    static var panelStrongColor: Color { Color(nsColor: panelStrong) }

    static func sourceCardBackground(accent: NSColor) -> some View {
        ZStack {
            cardColor
            Color(nsColor: accent)
                .opacity(isDark ? 0.18 : 0.12)
        }
        .clipShape(RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous))
    }

    // Snippet cards use the same stable content surface as clipboard cards.
    static func snippetCardBackground(elevated: Bool, in shape: some Shape = RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous)) -> some View {
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
                .easeOut(duration: 0.22)
                    .delay(Double(index) * MacClippyMotion.actionBarStaggerStep),
                value: appeared
            )
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
    static let contentFontSize: CGFloat = 13
    static let contentFont = Font.system(size: contentFontSize, weight: .regular)
    static let contentMonospacedFont = Font.system(size: contentFontSize, weight: .regular, design: .monospaced)
    // Reference-aligned subtle pointer hover lift (points). Applied only when
    // Reduce Motion is off so hover never moves content for users who opt out.
    static let hoverLift: CGFloat = -2
    // Vertical padding inside the horizontal carousel ScrollViews (applied to
    // the card row). Kept generous enough that a hovered card's 2pt border +
    // hoverLift offset (-2pt) + soft glow never clip against the scroll view's
    // bounds or the panel's top clip shape.
    static let carouselVerticalPadding: CGFloat = 10
    // Compact horizontal carousel height: the fixed card height plus the
    // vertical scroll padding on both sides. The populated horizontal carousel
    // is constrained to this so it never expands to fill the panel vertically.
    static var carouselHeight: CGFloat {
        height + carouselVerticalPadding * 2
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
    // P2a transient feedback for a custom label edit. cleared is true when the
    // label was blanked (set to nil), false when a non-empty label was saved.
    case labelSaved(cleared: Bool)
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
        case let .labelSaved(cleared): cleared ? "Label cleared" : "Label saved"
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
        case .copied, .pasted, .pinChanged, .pinnedTo, .snippetCreated, .deleted, .labelSaved,
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
           preferred.items.contains(where: { $0.id == itemID }) {
            return .unpin(boardName: preferred.name)
        }
        if let containing = pinboards.first(where: { $0.items.contains(where: { $0.id == itemID }) }) {
            return .unpin(boardName: containing.name)
        }
        guard let defaultBoard = pinboards.first else { return nil }
        return .pin(boardName: defaultBoard.name)
    }
}

@MainActor
final class MacClippyDockModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var historyItems: [MacClippyHistoryEntry] = []
    @Published private(set) var snippets: [MacClippySnippetEntry] = []
    @Published private(set) var pinboards: [MacClippyPinboardEntry] = []
    // Pre-computed consecutive-duplicate run counts keyed by record ID, so the
    // card view reads an O(1) lookup instead of an O(n²) scan on every focus
    // change. Recomputed only when the visible list changes (reload/tab switch).
    @Published private(set) var dedupRunCounts: [RecordID: Int] = [:]
    @Published private(set) var selectedTab: MacClippyDockTab = .history
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var focusedIndex = 0
    // Keyboard and preview navigation use this token to request a scroll into
    // view. Pointer selection intentionally leaves it unchanged so clicking a
    // card never recenters the carousel.
    @Published private(set) var focusFollowRequestID: UInt = 0
    // Capture the item that caused the request. The view may receive the
    // published token after another pointer selection has already changed
    // focusedIndex, so resolving the target from the latest index could scroll
    // the clicked card even though the click itself did not request a scroll.
    @Published private(set) var focusFollowTargetID: RecordID?
    // Mirrors the controller's Space-preview visibility so the card view can
    // render an active accent border on the focused card while previewing.
    // Toggled by the controller when the preview shows/hides.
    @Published var isPreviewVisible = false
    @Published private(set) var actionFeedback: MacClippyDockActionFeedback?
    @Published private(set) var modal: MacClippyDockModal?
    @Published private(set) var searchFocusRequest = 0
    @Published private(set) var searchFocusReset = 0
    // P1 multi-select state. The selection is active only on the history and
    // pinboard tabs (clipboard records); the snippets tab keeps the existing
    // single-focus path because snippet multi-select has no real ordered
    // multi-paste semantic in P1. The state is rebinding-cleaned on every
    // reload and tab switch so it can never reference a deleted or filtered-
    // out record.
    @Published private(set) var selection = MacClippyDockSelectionState()

    private let runtime: MacClippyRuntime
    private let workQueue = DispatchQueue(label: "com.macallyouneed.macclippy.dock", qos: .userInitiated)
    private let reloadQueue = DispatchQueue(label: "com.macallyouneed.macclippy.reload", qos: .userInitiated)
    private let previewQueue = DispatchQueue(label: "com.macallyouneed.macclippy.preview", qos: .userInitiated)
    private let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.macallyouneed.macclippy.thumbnail"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private let thumbnailCache = NSCache<NSString, NSData>()
    private struct ThumbnailRequestKey: Hashable {
        let id: RecordID
        let maxPixelSize: Int

        var cacheKey: NSString {
            "\(id.rawValue)#\(maxPixelSize)" as NSString
        }
    }
    private var thumbnailCompletions: [ThumbnailRequestKey: [(Data?) -> Void]] = [:]
    private var requestID = 0
    private var reloadWorkItem: DispatchWorkItem?
    private var previewWorkItem: DispatchWorkItem?
    private var isSelecting = false
    private var actionFeedbackTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    // P1 stale-operation guard. `sessionGeneration` is bumped on dock show/hide
    // so an async completion from a previous dock session cannot mutate state
    // or close a newly reopened dock. `operationGeneration` is bumped on every
    // batch operation start so a slow earlier batch cannot overwrite the
    // result of a newer batch. Each async batch completion captures the
    // generation it was started with and no-ops if it no longer matches.
    private var sessionGeneration: UInt = 0
    private var operationGeneration: UInt = 0
    // Label edits have their own generation because the inline editor can save
    // more than once without starting a batch operation. Only the newest save
    // in the current dock session may publish feedback or trigger a reload.
    private var labelOperationGeneration: UInt = 0
    private var modalPresentationToken: UInt = 0

    private struct Snapshot {
        let history: [MacClippyHistoryEntry]
        let snippets: [MacClippySnippetEntry]?
        let pinboards: [MacClippyPinboardEntry]?
    }

    init(runtime: MacClippyRuntime) {
        self.runtime = runtime
        thumbnailCache.totalCostLimit = 64 * 1024 * 1024
    }

    func presentCreateCategory() {
        modalPresentationToken &+= 1
        modal = .createCategory(token: modalPresentationToken)
    }

    func presentEditLabel(for entry: MacClippyHistoryEntry) {
        modalPresentationToken &+= 1
        modal = .editLabel(recordID: entry.id, initialLabel: entry.customLabel, token: modalPresentationToken)
    }

    func presentRenameCategory(for pinboard: MacClippyPinboardEntry) {
        modalPresentationToken &+= 1
        modal = .renameCategory(pinboardID: pinboard.id, token: modalPresentationToken)
    }

    func presentConfirmDeleteCategory(for pinboard: MacClippyPinboardEntry) {
        modalPresentationToken &+= 1
        modal = .confirmDeleteCategory(pinboardID: pinboard.id, name: pinboard.name, token: modalPresentationToken)
    }

    func dismissModal() {
        modal = nil
    }

    deinit {
        actionFeedbackTask?.cancel()
        reloadTask?.cancel()
        reloadWorkItem?.cancel()
        previewWorkItem?.cancel()
    }

    var visibleItems: [MacClippyHistoryEntry] {
        let source: [MacClippyHistoryEntry]
        switch selectedTab {
        case .history:
            source = historyItems
        case .snippets:
            source = []
        case let .pinboard(id):
            source = pinboards.first(where: { $0.id == id })?.items ?? []
        }
        return filter(source, by: query)
    }

    var visibleSnippets: [MacClippySnippetEntry] {
        guard selectedTab == .snippets else { return [] }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return snippets }
        return snippets.filter {
            [$0.name, $0.trigger ?? "", $0.body].contains { $0.localizedCaseInsensitiveContains(normalizedQuery) }
        }
    }

    var selectedPinboardName: String? {
        guard case let .pinboard(id) = selectedTab else { return nil }
        return pinboards.first(where: { $0.id == id })?.name
    }

    var focusedItem: MacClippyHistoryEntry? {
        guard selectedTab != .snippets else { return nil }
        return visibleItems.indices.contains(focusedIndex) ? visibleItems[focusedIndex] : nil
    }

    var focusedSnippet: MacClippySnippetEntry? {
        guard selectedTab == .snippets else { return nil }
        return visibleSnippets.indices.contains(focusedIndex) ? visibleSnippets[focusedIndex] : nil
    }

    var focusedPreviewTarget: MacClippyDockPreviewTarget? {
        if let focusedSnippet { return .snippet(focusedSnippet.id) }
        if let focusedItem { return .item(focusedItem.id) }
        return nil
    }

    var focusedPinAction: MacClippyDockPinAction? {
        guard let focusedItem else { return nil }
        return MacClippyDockPinResolver.action(
            for: focusedItem.id,
            selectedTab: selectedTab,
            pinboards: pinboards
        )
    }

    // Whether the multi-select action surface should be shown. The bar shows
    // only when MORE THAN ONE card is selected (count > 1): a single focused
    // card is not a "selection group" and should not show the multi-action bar.
    // A plain click collapses a multi-selection to one focused card, which
    // correctly dismisses the bar (intentional macOS semantic). Cmd-click
    // toggles keep the bar mounted while count > 1. The bar's exit transition
    // is a spring, so the dismissal reads as smooth rather than a hard cut.
    var hasMultipleSelection: Bool {
        selectedTab != .snippets && selection.hasMultiple
    }

    var selectionCount: Int {
        selectedTab == .snippets ? 0 : selection.count
    }

    // The target pinboard for a batch pin: the currently-viewed pinboard tab
    // if the user is looking at one, otherwise the first pinboard. nil when no
    // pinboard exists. Used by Cmd+P and the Pin all action.
    var batchPinTarget: MacClippyPinboardEntry? {
        if case let .pinboard(id) = selectedTab,
           let board = pinboards.first(where: { $0.id == id }) {
            return board
        }
        return pinboards.first
    }

    func reload(includeStaticData: Bool = true) {
        reloadTask?.cancel()
        reloadTask = nil
        reloadWorkItem?.cancel()
        requestID += 1
        let currentRequestID = requestID
        let query = query
        let runtime = runtime
        isLoading = true
        errorMessage = nil

        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [weak self, runtime] in
            guard !workItem.isCancelled else { return }
            let result = Result {
                Snapshot(
                    history: try runtime.history(
                        limit: 16,
                        query: query,
                        shouldCancel: { workItem.isCancelled }
                    ),
                    snippets: includeStaticData ? try runtime.snippets() : nil,
                    pinboards: includeStaticData ? try runtime.pinboards() : nil
                )
            }
            guard !workItem.isCancelled else { return }
            DispatchQueue.main.async {
                guard let self,
                      !workItem.isCancelled,
                      self.requestID == currentRequestID else { return }
                self.isLoading = false
                switch result {
                case let .success(snapshot):
                    self.historyItems = snapshot.history
                    if let snippets = snapshot.snippets {
                        self.snippets = snippets
                    }
                    if let pinboards = snapshot.pinboards {
                        self.pinboards = pinboards
                    }
                    self.reconcileSelectedTab()
                    self.focusedIndex = min(self.focusedIndex, max(0, self.currentCount - 1))
                    self.rebindSelection()
                    // A hotkey-opened picker must have one concrete card
                    // selected immediately. Without this, the first card can
                    // be focused by index but still look unselected, and
                    // Space has no stable picker target during the first
                    // interaction.
                    if self.selection.isEmpty, self.currentCount > 0, self.selectedTab != .snippets {
                        self.focusSelection(at: self.focusedIndex)
                    }
                    self.recomputeDedupRuns()
                case .failure:
                    // Keep the last successful snapshot visible. A transient
                    // query/database failure should not destroy the user's
                    // current history, snippets, pinboards, or selection;
                    // the error banner and the next reload provide recovery.
                    self.errorMessage = MacClippyUserFacingError.historyLoad
                }
            }
        }
        reloadWorkItem = workItem
        reloadQueue.async(execute: workItem)
    }

    func scheduleReload() {
        reloadTask?.cancel()
        // Search filtering for snippets and pinboards is local. Only history
        // needs a database query when the user types; avoid a full snapshot
        // reload (snippets + every pinboard) on every keystroke.
        guard selectedTab == .history else { return }
        reloadTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.reload(includeStaticData: false)
        }
    }

    func requestSearchFocus() {
        searchFocusRequest &+= 1
    }

    func resetSearchFocus() {
        searchFocusReset &+= 1
    }

    func setErrorForDetails(_ message: String) {
        errorMessage = message
    }

    func appendSearchText(_ text: String) {
        query.append(text)
    }

    func deleteSearchCharacter() {
        guard !query.isEmpty else { return }
        query.removeLast()
    }

    func loadPreview(
        for target: MacClippyDockPreviewTarget,
        completion: @escaping (Result<MacClippyRuntimePreviewPayload, Error>) -> Void
    ) {
        previewWorkItem?.cancel()
        let runtime = runtime
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem { [runtime] in
            guard !workItem.isCancelled else { return }
            let result = Result {
                switch target {
                case let .item(id):
                    try runtime.preview(id: id)
                case let .snippet(id):
                    try runtime.preview(snippetID: id)
                }
            }
            guard !workItem.isCancelled else { return }
            DispatchQueue.main.async {
                guard !workItem.isCancelled else { return }
                completion(result)
            }
        }
        previewWorkItem = workItem
        previewQueue.async(execute: workItem)
    }

    func loadDetails(
        for id: RecordID,
        completion: @escaping (Result<MacClippyItemDetails, Error>) -> Void
    ) {
        let runtime = runtime
        workQueue.async { [runtime] in
            let result = Result { try runtime.details(id: id) }
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func editDetails(id: RecordID, text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let runtime = runtime
        let session = sessionGeneration
        workQueue.async { [weak self, runtime] in
            let result = Result { _ = try runtime.edit(id: id, text: text) }
            DispatchQueue.main.async {
                guard let self, self.sessionGeneration == session else { return }
                completion(result.map { _ in () })
                if case .success = result {
                    self.reload()
                }
            }
        }
    }

    func renameDetails(id: RecordID, label: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        let runtime = runtime
        let session = sessionGeneration
        workQueue.async { [weak self, runtime] in
            let result = Result { _ = try runtime.setCustomLabel(id: id, label: label) }
            DispatchQueue.main.async {
                guard let self, self.sessionGeneration == session else { return }
                completion(result.map { _ in () })
                if case .success = result {
                    self.reload()
                }
            }
        }
    }

    // Card thumbnails use their own non-cancelled path. The Space Preview
    // loader is latest-wins by design, but using it for every visible image
    // card would make thumbnails cancel one another. Downsample before the
    // result reaches SwiftUI and cache by record ID.
    func loadImageThumbnail(
        for id: RecordID,
        maxPixelSize: Int = 480,
        completion: @escaping (Data?) -> Void
    ) {
        let requestKey = ThumbnailRequestKey(id: id, maxPixelSize: max(1, maxPixelSize))
        if let cached = thumbnailCache.object(forKey: requestKey.cacheKey) {
            completion(cached as Data)
            return
        }
        if thumbnailCompletions[requestKey] != nil {
            thumbnailCompletions[requestKey, default: []].append(completion)
            return
        }
        thumbnailCompletions[requestKey] = [completion]

        let runtime = runtime
        thumbnailQueue.addOperation { [weak self, runtime] in
            var thumbnailData: Data?
            if let data = try? runtime.imageData(id: id) {
                thumbnailData = MacClippyThumbnailDownsampler.data(data, maxPixelSize: requestKey.maxPixelSize)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                if let thumbnailData {
                    self.thumbnailCache.setObject(
                        thumbnailData as NSData,
                        forKey: requestKey.cacheKey,
                        cost: thumbnailData.count
                    )
                }
                let completions = self.thumbnailCompletions.removeValue(forKey: requestKey) ?? []
                completions.forEach { $0(thumbnailData) }
            }
        }
    }

    func selectTab(_ tab: MacClippyDockTab) {
        guard tab != selectedTab else { return }
        selectedTab = tab
        focusedIndex = 0
        errorMessage = nil
        // Clearing the selection on a tab switch keeps the multi-select surface
        // scoped to one visible list; a stale selection from the previous tab
        // would reference IDs that are not in the new visible list.
        selection = MacClippyDockSelectionState()
        recomputeDedupRuns()
    }

    // Recompute the consecutive-duplicate run counts for the current visible
    // list. O(n) once per list change; the card view then reads an O(1) lookup.
    // A run is a maximal group of adjacent items with the same contentKind +
    // preview. Only the first item of each run gets a count > 1 (the badge
    // host); followers map to 1 so they show no badge.
    private func recomputeDedupRuns() {
        let items = visibleItems
        guard !items.isEmpty else { dedupRunCounts = [:]; return }
        var counts: [RecordID: Int] = [:]
        var runStart = 0
        for i in 1...items.count {
            let breaksRun = (i == items.count)
                || items[i].contentKind != items[runStart].contentKind
                || items[i].preview != items[runStart].preview
            if breaksRun {
                let runLength = i - runStart
                counts[items[runStart].id] = runLength
                runStart = i
            }
        }
        dedupRunCounts = counts
    }

    // P1: rebind the selection to the current visible-items list, dropping any
    // selected ID that is no longer present and clamping focus/anchor. Called
    // after a reload and before any selection mutation so the selection state
    // never references a deleted or filtered-out record.
    private func rebindSelection() {
        guard selectedTab != .snippets else {
            selection = MacClippyDockSelectionState()
            return
        }
        let ordered = visibleItems.map(\.id)
        selection = MacClippyDockSelectionPolicy.rebinding(selection, to: ordered)
        if selection.focusedIndex != focusedIndex {
            focusedIndex = selection.focusedIndex
        }
    }

    // P1 selection mutations. Each method applies the pure policy and then
    // syncs the model's focusedIndex from the resulting state so the keyboard
    // cursor and the selection focus stay consistent. On the snippets tab the
    // selection is never active and these are no-ops.

    func focusSelection(at index: Int) {
        guard selectedTab != .snippets else {
            focusedIndex = index
            return
        }
        rebindSelection()
        selection = MacClippyDockSelectionPolicy.focusing(selection, at: index)
        focusedIndex = selection.focusedIndex
    }

    func toggleSelection(at index: Int) {
        guard selectedTab != .snippets else { return }
        rebindSelection()
        selection = MacClippyDockSelectionPolicy.toggling(selection, at: index)
        focusedIndex = selection.focusedIndex
    }

    func extendRange(to index: Int) {
        guard selectedTab != .snippets else { return }
        rebindSelection()
        selection = MacClippyDockSelectionPolicy.extendingRange(selection, to: index)
        focusedIndex = selection.focusedIndex
    }

    func extendRangeByStep(_ direction: MacClippyDockSelectionDirection) {
        guard selectedTab != .snippets else { return }
        rebindSelection()
        selection = MacClippyDockSelectionPolicy.extendingRangeByStep(selection, direction: direction)
        focusedIndex = selection.focusedIndex
        requestFocusFollow()
    }

    func moveFocus(_ direction: MacClippyDockSelectionDirection) {
        guard currentCount > 0 else { return }
        if selectedTab == .snippets {
            let offset = direction == .left ? -1 : 1
            focusedIndex = (focusedIndex + offset + currentCount) % currentCount
            requestFocusFollow()
            return
        }
        rebindSelection()
        selection = MacClippyDockSelectionPolicy.movingFocus(selection, direction: direction)
        focusedIndex = selection.focusedIndex
        requestFocusFollow()
    }

    private func requestFocusFollow() {
        focusFollowTargetID = selectedTab == .snippets ? focusedSnippet?.id : focusedItem?.id
        focusFollowRequestID &+= 1
    }

    func selectAllVisible() {
        guard selectedTab != .snippets else { return }
        rebindSelection()
        selection = MacClippyDockSelectionPolicy.selectingAll(selection)
        focusedIndex = selection.focusedIndex
    }

    func clearSelection() {
        guard selectedTab != .snippets else { return }
        rebindSelection()
        selection = MacClippyDockSelectionPolicy.clearingSelection(selection)
        focusedIndex = selection.focusedIndex
    }

    func isSelected(_ id: RecordID) -> Bool {
        selectedTab != .snippets && selection.contains(id)
    }

    // P1 session generation. Bumped by the dock controller on show/hide so a
    // stale async batch completion from a previous dock session cannot mutate
    // state or close a newly reopened dock.
    func beginSession() {
        sessionGeneration &+= 1
        operationGeneration &+= 1
        labelOperationGeneration &+= 1
        isSelecting = false
        query = ""
        focusedIndex = 0
        selection = MacClippyDockSelectionState()
    }

    func endSession() {
        sessionGeneration &+= 1
        operationGeneration &+= 1
        labelOperationGeneration &+= 1
        isSelecting = false
        clearActionFeedback()
    }

    func activate(_ item: MacClippyHistoryEntry, completion: @escaping () -> Void) {
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else { return }
        focusedIndex = index
        guard item.isPasteable else { return }
        select(item, completion: completion)
    }

    func activate(_ snippet: MacClippySnippetEntry, completion: @escaping () -> Void) {
        guard let index = visibleSnippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        focusedIndex = index
        select(snippet, completion: completion)
    }

    func focus(_ item: MacClippyHistoryEntry) {
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else { return }
        focusedIndex = index
    }

    func focusAndSelect(_ item: MacClippyHistoryEntry) {
        guard let index = visibleItems.firstIndex(where: { $0.id == item.id }) else { return }
        focusSelection(at: index)
    }

    func ensureFocusedSelection() {
        guard selectedTab != .snippets, currentCount > 0 else { return }
        focusedIndex = min(max(focusedIndex, 0), currentCount - 1)
        if selection.isEmpty {
            focusSelection(at: focusedIndex)
        }
    }

    func focus(_ snippet: MacClippySnippetEntry) {
        guard let index = visibleSnippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        focusedIndex = index
    }

    func pasteFocused(completion: @escaping () -> Void) {
        if selectedTab == .snippets {
            guard let snippet = focusedSnippet else { return }
            activate(snippet, completion: completion)
        } else if let item = focusedItem {
            activate(item, completion: completion)
        }
    }

    func activateShortcut(_ number: Int, completion: @escaping () -> Void) {
        let index = number - 1
        guard index >= 0, index < currentCount else { return }
        focusedIndex = index
        pasteFocused(completion: completion)
    }

    func copyFocused() {
        copyFocused(plain: false)
    }

    func copyFocused(plain: Bool, completion: (() -> Void)? = nil) {
        let runtime = runtime
        let feedback: MacClippyDockActionFeedback = .copied(plain: plain)
        if selectedTab == .snippets, let snippet = focusedSnippet {
            perform({ [runtime] in try runtime.copy(snippetID: snippet.id) }, onSuccess: { [weak self] in
                self?.showActionFeedback(feedback)
                completion?()
            })
        } else if let item = focusedItem {
            perform({ [runtime] in try runtime.copy(id: item.id, plain: plain) }, onSuccess: { [weak self] in
                self?.showActionFeedback(feedback)
                completion?()
            })
        }
    }

    // Transformed copy/paste of the focused card. Both act on the focused
    // clipboard record (the context menu focuses the card before invoking).
    // Only text/html/rtf records are supported; the runtime rejects image/
    // files and undecodable payloads with an explicit error, which surfaces
    // via errorMessage so nothing is silently transformed or dropped. Copy
    // keeps the dock open (no completion) and shows transformedCopied
    // feedback, matching copyFocused. Paste uses the same async + session-
    // generation guard as select(item:completion:) so a stale completion from
    // a previous dock session cannot close a newly reopened dock, and calls
    // completion (closing the dock) only on a successful paste.
    func copyFocused(transform: TextTransform) {
        guard let item = focusedItem else { return }
        let runtime = runtime
        let name = transform.displayName
        perform({ [runtime] in try runtime.copy(id: item.id, transform: transform) }, onSuccess: { [weak self] in
            self?.showActionFeedback(.transformedCopied(name: name))
        })
    }

    func pasteFocused(transform: TextTransform, completion: @escaping () -> Void) {
        guard let item = focusedItem else { return }
        let runtime = runtime
        let name = transform.displayName
        let session = sessionGeneration
        errorMessage = nil

        workQueue.async { [weak self, runtime] in
            let result = Result { try runtime.paste(id: item.id, transform: transform) }
            DispatchQueue.main.async {
                guard let self, self.sessionGeneration == session else { return }
                switch result {
                case let .success(pasteResult):
                    self.showActionFeedback(.transformedPasted(name: name, manual: pasteResult == .manualPasteRequired))
                    completion()
                case .failure:
                    self.errorMessage = MacClippyUserFacingError.genericAction
                }
            }
        }
    }

    func togglePinFocused(in pinboardID: RecordID) {
        guard let item = focusedItem else { return }
        let runtime = runtime
        let pinAction = focusedPinAction
        perform({ [item] in
            try runtime.togglePin(id: item.id, preferredPinboardID: pinboardID)
            return true
        }, onSuccess: { [weak self] in
            guard let self else { return }
            if case let .pin(boardName) = pinAction {
                self.showActionFeedback(.pinChanged(boardName: boardName, isPinned: true))
            } else if case let .unpin(boardName) = pinAction {
                self.showActionFeedback(.pinChanged(boardName: boardName, isPinned: false))
            }
            self.reload()
        })
    }

    func togglePinFocused(completion: (() -> Void)? = nil) {
        guard let item = focusedItem else { return }
        let runtime = runtime
        perform({ [item] in
            try runtime.togglePin(id: item.id)
            return true
        }, onSuccess: { [weak self] in
            self?.reload()
            completion?()
        })
    }

    // P2a: set or clear the focused card's custom label. The runtime trims the
    // label (blank -> nil clears it), persists it, and reindexes the search
    // store so the label is searchable without losing existing searchable
    // text. The model reports transient labelSaved feedback and reloads so the
    // card immediately reflects the new label. Reload is safe: it cancels any
    // in-flight reload and rebinds the selection, so a label edit can never
    // leave a stale card or a stale selection.
    func setLabelFocused(_ label: String?) {
        guard let item = focusedItem else { return }
        setLabel(for: item.id, label: label)
    }

    // P2a: set or clear a label for an arbitrary visible record (used by the
    // inline editor when the edited card is not the focused one). Same
    // trim/persist/reindex/reload semantics as setLabelFocused.
    func setLabel(for id: RecordID, label: String?) {
        let runtime = runtime
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let willClear = (trimmed?.isEmpty ?? true)
        labelOperationGeneration &+= 1
        let labelGeneration = labelOperationGeneration
        let session = sessionGeneration
        errorMessage = nil

        workQueue.async { [weak self, runtime] in
            let result = Result {
                _ = try runtime.setCustomLabel(id: id, label: label)
                return true
            }
            DispatchQueue.main.async {
                guard let self,
                      self.sessionGeneration == session,
                      self.labelOperationGeneration == labelGeneration else { return }
                switch result {
                case .success:
                    self.showActionFeedback(.labelSaved(cleared: willClear))
                    self.reload()
                case .failure:
                    self.errorMessage = MacClippyUserFacingError.genericAction
                }
            }
        }
    }

    func pin(recordID: RecordID, to pinboard: MacClippyPinboardEntry) {
        let runtime = runtime
        perform({
            try runtime.pin(recordID: recordID, to: pinboard.id)
            return true
        }, onSuccess: { [weak self] in
            self?.showActionFeedback(.pinnedTo(boardName: pinboard.name))
            self?.reload()
        })
    }

    func createSnippet(from recordID: RecordID) {
        let runtime = runtime
        let session = sessionGeneration
        errorMessage = nil

        workQueue.async { [weak self, runtime] in
            let result = Result { try runtime.createSnippet(from: recordID) }
            DispatchQueue.main.async {
                guard let self, self.sessionGeneration == session else { return }
                switch result {
                case .success:
                    self.showActionFeedback(.snippetCreated)
                    self.reload()
                case let .failure(error):
                    if error is MacClippySnippetCreationError {
                        self.errorMessage = MacClippyUserFacingError.snippetTextOnly
                    } else {
                        self.errorMessage = MacClippyUserFacingError.genericAction
                    }
                }
            }
        }
    }

    func createSnippet(
        name: String,
        trigger: String?,
        body: String,
        onSuccess: (() -> Void)? = nil,
        onFailure: ((String) -> Void)? = nil
    ) {
        let runtime = runtime
        errorMessage = nil

        workQueue.async { [weak self, runtime] in
            let result = Result {
                try runtime.createSnippet(name: name, trigger: trigger, body: body)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.showActionFeedback(.snippetCreated)
                    self.reload()
                    onSuccess?()
                case let .failure(error):
                    let message: String
                    switch error as? MacClippySnippetCreationError {
                    case .invalidName:
                        message = "Enter a name for this snippet."
                    case .emptyBody:
                        message = "Enter some content for this snippet."
                    case .duplicateTrigger:
                        message = "That trigger is already in use."
                    default:
                        message = MacClippyUserFacingError.genericAction
                    }
                    onFailure?(message)
                }
            }
        }
    }

    func createPinboard(name: String, color: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let runtime = runtime
        workQueue.async { [weak self, runtime] in
            let result = Result { try runtime.createPinboard(name: trimmedName, color: color) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .success(board):
                    self.selectTab(.pinboard(board.id))
                    self.reload()
                case .failure:
                    self.errorMessage = MacClippyUserFacingError.genericAction
                }
            }
        }
    }

    func renamePinboard(_ pinboard: MacClippyPinboardEntry, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        let runtime = runtime
        perform({
            try runtime.renamePinboard(id: pinboard.id, to: trimmedName)
            return true
        }, onSuccess: { [weak self] in
            self?.reload()
        })
    }

    func setPinboardColor(_ pinboard: MacClippyPinboardEntry, to color: String) {
        let runtime = runtime
        perform({
            try runtime.setPinboardColor(id: pinboard.id, color: color)
            return true
        }, onSuccess: { [weak self] in
            self?.reload()
        })
    }

    func deletePinboard(_ pinboard: MacClippyPinboardEntry) {
        let runtime = runtime
        perform({
            try runtime.deletePinboard(id: pinboard.id)
            return true
        }, onSuccess: { [weak self] in
            self?.reload()
        })
    }

    func isPinned(_ itemID: RecordID, in pinboard: MacClippyPinboardEntry) -> Bool {
        pinboard.items.contains { $0.id == itemID }
    }

    func deleteFocused() {
        let runtime = runtime
        if selectedTab == .snippets, let snippet = focusedSnippet {
            perform({
                try runtime.delete(snippetID: snippet.id)
                return true
            }, onSuccess: { [weak self] in
                self?.showActionFeedback(.deleted)
                self?.reload()
            })
        } else if let item = focusedItem {
            perform({
                try runtime.delete(id: item.id)
                return true
            }, onSuccess: { [weak self] in
                self?.showActionFeedback(.deleted)
                self?.reload()
            })
        } else {
            return
        }
    }

    // P1 batch actions. Each one captures the session and operation generation
    // at start and verifies both on completion, so a stale completion from a
    // previous dock session or a superseded batch cannot mutate state or close
    // a newly reopened dock. All batch actions act only on the selected record
    // IDs and never inspect or filter their content (no-filter semantics).

    func pasteSelectedAll(completion: @escaping () -> Void) {
        guard selectedTab != .snippets, selection.hasMultiple else {
            pasteFocused(completion: completion)
            return
        }
        let orderedIDs = selection.orderedSelectedIDs
        guard !orderedIDs.isEmpty else { return }

        operationGeneration &+= 1
        let opGeneration = operationGeneration
        let session = sessionGeneration
        let runtime = runtime
        errorMessage = nil

        workQueue.async { [weak self, runtime] in
            let result = Result { try runtime.pasteOrdered(ids: orderedIDs) }
            DispatchQueue.main.async {
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == opGeneration else { return }
                switch result {
                case let .success(pasteResult):
                    switch pasteResult {
                    case let .merged(injected):
                        self.showActionFeedback(.pasted(manual: !injected))
                        completion()
                    case let .mixed(supportedIDs, unsupportedIDs, unsupportedKinds):
                        // Never paste a subset of a mixed selection. Show
                        // transient feedback naming the unsupported kinds so
                        // the user knows exactly what was not pasted.
                        self.showActionFeedback(.multiPasteMixed(
                            supportedCount: supportedIDs.count,
                            unsupportedCount: unsupportedIDs.count,
                            unsupportedKinds: unsupportedKinds
                        ))
                    case let .textUnavailable(availableIDs, unavailableIDs, unavailableKinds):
                        // Never paste when a text-compatible payload was
                        // unavailable/undecodable; merging it as an empty
                        // piece would be silent data loss. Name the
                        // unavailable kinds so the user knows exactly which
                        // records could not be pasted.
                        self.showActionFeedback(.multiPasteUnavailable(
                            availableCount: availableIDs.count,
                            unavailableCount: unavailableIDs.count,
                            unavailableKinds: unavailableKinds
                        ))
                    }
                case .failure:
                    self.errorMessage = MacClippyUserFacingError.genericAction
                }
            }
        }
    }

    func copySelectedAll() {
        guard selectedTab != .snippets, selection.hasMultiple else {
            copyFocused()
            return
        }
        let orderedIDs = selection.orderedSelectedIDs
        guard !orderedIDs.isEmpty else { return }

        operationGeneration &+= 1
        let opGeneration = operationGeneration
        let session = sessionGeneration
        let runtime = runtime
        errorMessage = nil

        // Copy all prepares the merged homogeneous text on the pasteboard
        // WITHOUT injecting a paste keystroke, mirroring the paste-all merge
        // so a subsequent paste in any app produces the same concatenated
        // text. Mixed/unavailable selections report the unsupported/undecodable
        // kinds; nothing is silently dropped and no subset is prepared.
        workQueue.async { [weak self, runtime] in
            let resolution = Result { try runtime.copyOrdered(ids: orderedIDs) }
            DispatchQueue.main.async {
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == opGeneration else { return }
                switch resolution {
                case let .success(.merged(prepared)):
                    // prepared is the pasteboard write result; Copy all does
                    // not post a paste keystroke, so prepared is the only
                    // success signal. Show copied feedback either way (a
                    // failed write would have thrown before reaching here).
                    _ = prepared
                    self.showActionFeedback(.copied(plain: false))
                case let .success(.mixed(supportedIDs, unsupportedIDs, unsupportedKinds)):
                    self.showActionFeedback(.multiPasteMixed(
                        supportedCount: supportedIDs.count,
                        unsupportedCount: unsupportedIDs.count,
                        unsupportedKinds: unsupportedKinds
                    ))
                case let .success(.textUnavailable(availableIDs, unavailableIDs, unavailableKinds)):
                    self.showActionFeedback(.multiPasteUnavailable(
                        availableCount: availableIDs.count,
                        unavailableCount: unavailableIDs.count,
                        unavailableKinds: unavailableKinds
                    ))
                case .failure:
                    self.errorMessage = MacClippyUserFacingError.genericAction
                }
            }
        }
    }

    // Mixed-content sequential queue paste for the current ordered multi-
    // selection. Processes the selected IDs one at a time in visual order,
    // injecting a separate Cmd+V per record so mixed selections (text + image
    // + files) can each be consumed by the target app. Session/operation
    // generation guards match pasteSelectedAll so a stale completion from a
    // previous dock session cannot mutate state or close a newly reopened dock.
    // A single-selection fallback routes through the existing pasteFocused
    // path, matching pasteSelectedAll's fallback. Full success (every record
    // injected, no unavailable and no manual stop) closes the dock through the
    // existing completion; partial completion (some unavailable) and manual-
    // paste stop keep the dock open so the explicit result is visible. No
    // success is reported for skipped or unconsumed IDs.
    func pasteQueued(completion: @escaping () -> Void) {
        guard selectedTab != .snippets, selection.hasMultiple else {
            pasteFocused(completion: completion)
            return
        }
        let orderedIDs = selection.orderedSelectedIDs
        guard !orderedIDs.isEmpty else { return }

        operationGeneration &+= 1
        let opGeneration = operationGeneration
        let session = sessionGeneration
        let runtime = runtime
        errorMessage = nil

        workQueue.async { [weak self, runtime] in
            let result = Result { try runtime.pasteQueued(ids: orderedIDs) }
            DispatchQueue.main.async {
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == opGeneration else { return }
                switch result {
                case let .success(queueResult):
                    switch queueResult {
                    case let .completed(injectedIDs, unavailableIDs, unavailableKinds):
                        if unavailableIDs.isEmpty {
                            // Full success: every selected record was injected.
                            // Close the dock through the existing completion.
                            self.showActionFeedback(.queuePasteCompleted(
                                injectedCount: injectedIDs.count,
                                unavailableCount: 0
                            ))
                            completion()
                        } else {
                            // Partial completion: some records were injected
                            // and some were unavailable. Keep the dock open so
                            // the explicit result is visible; do not report
                            // success for the unavailable IDs.
                            self.showActionFeedback(.queuePastePartial(
                                injectedCount: injectedIDs.count,
                                unavailableCount: unavailableIDs.count,
                                unavailableKinds: unavailableKinds
                            ))
                        }
                    case let .manualPasteRequired(injectedIDs, unavailableIDs, unavailableKinds, manualPasteRequiredID, remainingIDs):
                        // Manual-paste stop: the current pasteboard item was
                        // not consumed automatically. Keep the dock open so the
                        // unconsumed IDs are visible; do not claim the current
                        // or any remaining ID injected.
                        _ = unavailableIDs
                        _ = unavailableKinds
                        _ = manualPasteRequiredID
                        self.showActionFeedback(.queuePasteManualStop(
                            injectedCount: injectedIDs.count,
                            remainingCount: remainingIDs.count
                        ))
                    }
                case .failure:
                    self.errorMessage = MacClippyUserFacingError.genericAction
                }
            }
        }
    }

    func deleteSelected() {
        guard selectedTab != .snippets, !selection.isEmpty else {
            deleteFocused()
            return
        }
        let orderedIDs = selection.orderedSelectedIDs
        guard !orderedIDs.isEmpty else { return }

        operationGeneration &+= 1
        let opGeneration = operationGeneration
        let session = sessionGeneration
        let runtime = runtime
        errorMessage = nil

        workQueue.async { [weak self, runtime] in
            let result = Result { try runtime.delete(ids: orderedIDs) }
            DispatchQueue.main.async {
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == opGeneration else { return }
                switch result {
                case let .success(batchResult):
                    // A complete success requires both no missing IDs and no
                    // per-item failures; otherwise report a partial result so
                    // a failing item can never silently make the UI report a
                    // complete batch. Reload always so the list reflects the
                    // partial deletion instead of going stale.
                    if batchResult.missingIDs.isEmpty, batchResult.failedIDs.isEmpty {
                        self.showActionFeedback(.deleted)
                    } else {
                        let succeeded = batchResult.deletedIDs.count
                        let unsupported = batchResult.missingIDs.count + batchResult.failedIDs.count
                        self.showActionFeedback(.batchPartial(
                            succeeded: succeeded,
                            unsupported: unsupported
                        ))
                    }
                    self.selection = MacClippyDockSelectionState()
                    self.reload()
                case .failure:
                    self.errorMessage = MacClippyUserFacingError.genericAction
                }
            }
        }
    }

    func pinSelected() {
        guard selectedTab != .snippets, !selection.isEmpty,
              let target = batchPinTarget else {
            return
        }
        let orderedIDs = selection.orderedSelectedIDs
        guard !orderedIDs.isEmpty else { return }

        operationGeneration &+= 1
        let opGeneration = operationGeneration
        let session = sessionGeneration
        let runtime = runtime
        errorMessage = nil

        workQueue.async { [weak self, runtime] in
            let result = Result { try runtime.pin(recordIDs: orderedIDs, to: target.id) }
            DispatchQueue.main.async {
                guard let self,
                      self.sessionGeneration == session,
                      self.operationGeneration == opGeneration else { return }
                switch result {
                case let .success(batchResult):
                    // A complete success requires both no missing IDs and no
                    // per-item failures; otherwise report a partial result so
                    // a failing item can never silently make the UI report a
                    // complete batch. Clear selection and reload always so the
                    // board reflects the partial pin instead of going stale.
                    if batchResult.missingIDs.isEmpty, batchResult.failedIDs.isEmpty {
                        self.showActionFeedback(.pinnedTo(boardName: batchResult.boardName))
                    } else {
                        let succeeded = batchResult.pinnedIDs.count
                        let unsupported = batchResult.missingIDs.count + batchResult.failedIDs.count
                        self.showActionFeedback(.batchPartial(
                            succeeded: succeeded,
                            unsupported: unsupported
                        ))
                    }
                    self.clearSelection()
                    self.reload()
                case .failure:
                    self.errorMessage = MacClippyUserFacingError.genericAction
                }
            }
        }
    }

    private func select(_ item: MacClippyHistoryEntry, completion: @escaping () -> Void) {
        guard !isSelecting else { return }
        let runtime = runtime
        let session = sessionGeneration
        isSelecting = true
        errorMessage = nil

        workQueue.async { [weak self, runtime] in
            let result = Result { try runtime.paste(id: item.id) }
            DispatchQueue.main.async {
                guard let self, self.sessionGeneration == session else { return }
                self.isSelecting = false
                switch result {
                case let .success(pasteResult):
                    self.showActionFeedback(.pasted(manual: pasteResult == .manualPasteRequired))
                    completion()
                case .failure:
                    self.errorMessage = MacClippyUserFacingError.genericAction
                }
            }
        }
    }

    private func select(_ snippet: MacClippySnippetEntry, completion: @escaping () -> Void) {
        guard !isSelecting else { return }
        let runtime = runtime
        let session = sessionGeneration
        isSelecting = true
        errorMessage = nil

        workQueue.async { [weak self, runtime] in
            let result = Result { try runtime.paste(snippetID: snippet.id) }
            DispatchQueue.main.async {
                guard let self, self.sessionGeneration == session else { return }
                self.isSelecting = false
                switch result {
                case let .success(pasteResult):
                    self.showActionFeedback(.pasted(manual: pasteResult == .manualPasteRequired))
                    completion()
                case .failure:
                    self.errorMessage = MacClippyUserFacingError.genericAction
                }
            }
        }
    }

    private var currentCount: Int {
        selectedTab == .snippets ? visibleSnippets.count : visibleItems.count
    }

    private func reconcileSelectedTab() {
        if case let .pinboard(id) = selectedTab,
           !pinboards.contains(where: { $0.id == id }) {
            selectedTab = .history
        }
    }

    private func filter(_ items: [MacClippyHistoryEntry], by query: String) -> [MacClippyHistoryEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty, selectedTab != .history else { return items }
        // P2b: apply the structured search grammar to pinboard-tab filtering
        // so a query like type:image or label:work narrows a pinboard the
        // same way it narrows history. The history tab is unaffected here
        // because its results already come from runtime.history (which
        // applies the same grammar), so the dock never re-filters history.
        let parsed = MacClippySearchGrammar.parse(normalizedQuery)
        // No structured clauses: preserve the existing local substring filter
        // on the raw query so bare-term pinboard search behavior is
        // unchanged.
        guard parsed.hasStructuredClauses else {
            return items.filter { $0.preview.localizedCaseInsensitiveContains(normalizedQuery) }
        }
        return items.filter { entry in
            let record = MacClippySearchGrammar.SearchRecord(
                contentKind: entry.contentKind,
                sourceAppBundleID: entry.meta.sourceAppBundleID,
                customLabel: entry.meta.customLabel,
                ocrText: entry.meta.ocrText,
                modified: entry.meta.modified
            )
            guard MacClippySearchGrammar.matches(parsed, record: record) else { return false }
            // AND with the existing bare-term substring on the preview so a
            // mixed query (e.g. important type:text) still narrows by the
            // bare portion too. With no bare terms, only the structured
            // predicate applies.
            if parsed.bareTerms.isEmpty { return true }
            let bare = parsed.bareTerms.joined(separator: " ")
            return entry.preview.localizedCaseInsensitiveContains(bare)
        }
    }

    private func perform(_ operation: @escaping () throws -> Bool, onSuccess: (() -> Void)? = nil) {
        errorMessage = nil
        let session = sessionGeneration
        workQueue.async { [weak self] in
            let result = Result { try operation() }
            DispatchQueue.main.async {
                guard let self, self.sessionGeneration == session else { return }
                switch result {
                case .success:
                    onSuccess?()
                case .failure:
                    self.errorMessage = MacClippyUserFacingError.genericAction
                }
            }
        }
    }

    func clearActionFeedback() {
        actionFeedbackTask?.cancel()
        actionFeedbackTask = nil
        actionFeedback = nil
    }

    private func showActionFeedback(_ feedback: MacClippyDockActionFeedback) {
        actionFeedbackTask?.cancel()
        actionFeedback = feedback
        actionFeedbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(MacClippyMotion.actionFeedbackLifetime * 1_000_000_000))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.actionFeedback = nil
            self.actionFeedbackTask = nil
        }
    }
}

private struct MacClippyCardHoverModifier: ViewModifier {
    let enabled: Bool
    let reduceMotion: Bool
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let active = enabled && isHovered
        return content
            .offset(y: reduceMotion || !active ? 0 : MacClippyDockCardMetrics.hoverLift)
            .shadow(color: active ? .black.opacity(0.10) : .clear, radius: active ? 14 : 0, y: 4)
            .animation(MacClippyMotion.animation(MacClippyMotion.focusAnimation, reduceMotion: reduceMotion), value: active)
            .onHover { hovering in
                isHovered = enabled && hovering
            }
    }
}

struct MacClippyDockView: View {
    @ObservedObject var model: MacClippyDockModel
    let onClose: () -> Void
    let onCreateSnippet: () -> Void
    let onEnterPickerMode: () -> Void
    let onSearchModeChange: (Bool) -> Void
    let onModalPresentationChange: (Bool) -> Void
    let onReduceMotionChange: (Bool) -> Void
    let onLayoutHeightChange: (Bool) -> Void
    // Screen-level copy toast callback. When the model surfaces a .copied
    // feedback, the view calls this so the controller can show a floating
    // toast outside the dock instead of an in-panel overlay.
    let onCopyToast: (String) -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @FocusState private var isSearchFocused: Bool
    @State private var dropTargetPinboardID: RecordID?
    @State private var dropConfirmedPinboardID: RecordID?
    @State private var dropTargetSnippets = false
    @State private var dropConfirmedSnippets = false
    // P2a: inline custom-label editor state is owned by the dock model and is
    // presented inside this panel, so keyboard events stay with the editor.
    // Pointer hover state for the +New category pill. Hover is border-only:
    // the dashed capsule border swaps to the accent color and thickens
    // slightly. There is no hover background fill, no hover foreground-color
    // change, and no vertical lift, so the pill never moves. Reduce Motion
    // keeps the instant border state.
    @State private var hoveredNewCategory = false
    // Hover state for filter/category pills so every interactive rail surface
    // has an instant hover indicator, not just the +New pill.
    @State private var hoveredFilterPill: String?
    // Gear/About button hover so it shares the same hover treatment as the
    // other circular icon buttons (+New).
    @State private var hoveredGear = false
    // One-shot flag for the action bar staggered button fade-in. Set on the
    // bar's first onAppear so buttons orchestrate left-to-right once.
    @State private var actionBarAppeared = false

    private var reduceMotion: Bool {
        MacClippyMotion.shouldReduceMotion(swiftUI: accessibilityReduceMotion)
    }

    var body: some View {
        VStack(spacing: 10) {
            // Header morphs in place between search mode and selection mode.
            // Both modes occupy the same fixed 48pt row, so switching never
            // resizes the panel — no vertical reflow, no dock resize. Selection
            // mode shows the count, a Cancel/Esc button, the action buttons,
            // and destructive Delete/Clear, all within the header.
            header
                .frame(height: 48)
                // Keep the selection morph scoped to the header. An animation
                // on the dock root also animates the carousel transaction when
                // selection changes, which can make its scroll position appear
                // to jump even though pointer selection never requests a
                // scroll.
                .animation(MacClippyMotion.animation(MacClippyMotion.actionBarEnterSpring, reduceMotion: reduceMotion), value: model.hasMultipleSelection)
            // The carousel container fills the width but does not force a
            // vertical stretch: the populated horizontal carousels constrain
            // themselves to MacClippyDockCardMetrics.carouselHeight, while the
            // loading/error/empty branches keep their own maxHeight: .infinity
            // so they center within the available panel space without adding
            // decorative edge overlays over the first and last cards.
            carousel
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Vibrancy material shell over the cool-neutral backdrop. The AppKit
        // backdrop paints the cool white/gray gradient; this thin material adds
        // the reference liquid-glass feel without hiding content.
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.55)
                .background(MacClippyDockTheme.panelStrongColor.opacity(0.18))
                .clipShape(TopRoundedRectangle(radius: 22))
                .overlay(TopRoundedRectangle(radius: 22).stroke(MacClippyDockTheme.lineColor, lineWidth: 1))
                .allowsHitTesting(false)
        )
        .clipShape(TopRoundedRectangle(radius: 22))
        .overlay {
            modalOverlay
        }
        .overlay(alignment: .topTrailing) {
            // In-panel feedback overlay skips .copied — copy confirmations get
            // a screen-level toast via onCopyToast instead, so the indicator
            // survives a dock close and reads like paste feedback.
            if let actionFeedback = model.actionFeedback, !actionFeedback.isCopyFeedback {
                actionFeedbackView(actionFeedback)
                    .padding(.top, 56)
                    .padding(.trailing, 18)
                    .transition(.opacity)
            }
        }
        .onChange(of: model.actionFeedback) { _, feedback in
            if let feedback, feedback.isCopyFeedback {
                onCopyToast(feedback.title)
            }
        }
        .animation(MacClippyMotion.animation(MacClippyMotion.actionFeedbackAnimation, reduceMotion: reduceMotion), value: model.actionFeedback)
        .onAppear {
            // Keyboard-first: do NOT auto-focus the search field on launch.
            // The first card is focusable; Cmd+K still focuses search on
            // demand via the controller key monitor.
            onReduceMotionChange(accessibilityReduceMotion)
        }
        .onChange(of: model.hasMultipleSelection) { _, hasMultipleSelection in
            onLayoutHeightChange(hasMultipleSelection)
        }
        .onChange(of: model.modal) { _, modal in
            // The modal is an in-panel overlay, so the search TextField can
            // still be the AppKit first responder when the overlay appears.
            // Release it before the modal editor requests focus; otherwise
            // printable keys continue to land in the main search field.
            if modal != nil {
                isSearchFocused = false
                onSearchModeChange(false)
            }
            onModalPresentationChange(modal != nil)
        }
    }

    // The header switches between search mode (default) and selection mode
    // (multi-select). Both occupy the same 48pt row; the switch is a content
    // cross-fade with a small vertical slide, never a panel resize.
    private var header: some View {
        ZStack {
            if model.hasMultipleSelection {
                selectionHeader
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                topRow
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // Selection-mode header: count + Cancel on the left, primary/secondary
    // actions in the center, destructive actions on the right. Replaces the
    // old bottom action bar so the eye never leaves the card area.
    private var selectionHeader: some View {
        GeometryReader { proxy in
            HStack(spacing: 8) {
                // Left: count badge (with number flip) + Cancel/Esc.
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text("\(model.selectionCount)")
                            .id(model.selectionCount)
                            .transition(MacClippyMotion.numberFlipTransition(reduceMotion: reduceMotion))
                        Text("selected")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MacClippyDockTheme.textColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MacClippyDockTheme.accentSoftColor, in: Capsule())
                    .animation(MacClippyMotion.animation(MacClippyMotion.focusAnimation, reduceMotion: reduceMotion), value: model.selectionCount)

                    Button {
                        model.clearSelection()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                            Text("Cancel")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(MacClippyDockTheme.mutedColor)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                    }
                    .buttonStyle(.plain)
                    .background(Capsule().fill(MacClippyDockTheme.cardColor.opacity(0.5)))
                    .pillBorder(MacClippyDockTheme.pillRestBorder)
                    .help("Exit selection (Esc)")
                }

                Spacer(minLength: 8)

                // Center/right actions, horizontally scrollable on narrow widths.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        SelectionBarButton("Paste all", systemImage: "arrow.down.doc", emphasis: .primary) {
                            model.pasteSelectedAll(completion: { [weak model] in
                                _ = model
                                onClose()
                            })
                        }
                        .staggeredAppearance(index: 0, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        SelectionBarButton("Queue paste", systemImage: "list.number") {
                            model.pasteQueued(completion: { [weak model] in
                                _ = model
                                onClose()
                            })
                        }
                        .staggeredAppearance(index: 1, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        SelectionBarButton("Copy all", systemImage: "doc.on.doc") {
                            model.copySelectedAll()
                        }
                        .staggeredAppearance(index: 2, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        if model.batchPinTarget != nil {
                            SelectionBarButton("Pin", systemImage: "pin") {
                                model.pinSelected()
                            }
                            .staggeredAppearance(index: 3, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        }
                        SelectionBarButton("Delete", systemImage: "trash", role: .destructive) {
                            model.deleteSelected()
                        }
                        .staggeredAppearance(index: 4, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                        SelectionBarButton("Clear", systemImage: "xmark", role: .destructive) {
                            model.clearSelection()
                        }
                        .staggeredAppearance(index: 5, appeared: actionBarAppeared, reduceMotion: reduceMotion)
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: proxy.size.width * 0.62, alignment: .trailing)
            }
        }
        .onAppear { actionBarAppeared = true }
        .onDisappear { actionBarAppeared = false }
    }

    // Single horizontal top row: the search field takes about 42% of the
    // available row width, the category/tag pills share the same row to its
    // right. Cmd+K focuses the SwiftUI search field (wired in the dock
    // controller); the field no longer auto-focuses on dock show — the dock
    // is keyboard-first and the first card is focusable. Settings opens via
    // a direct gear button. GeometryReader sizes the search field to ~42% of
    // the row width (clamped so it stays usable on very narrow and very wide
    // screens) without animating width on screen changes.
    private var topRow: some View {
        GeometryReader { proxy in
            let available = proxy.size.width
            let searchWidth = max(240, min(available * 0.42, 640))
            HStack(spacing: 10) {
                searchField
                    .frame(width: searchWidth, alignment: .leading)
                filterPillRow
            }
        }
        .onAppear {
            // Keyboard-first: do not steal focus into the search field on
            // launch. Reduce Motion is still reported to the controller.
            onReduceMotionChange(accessibilityReduceMotion)
        }
        .onChange(of: model.searchFocusRequest) { _, _ in isSearchFocused = true }
        .onChange(of: model.searchFocusReset) { _, _ in isSearchFocused = false }
        .onChange(of: accessibilityReduceMotion) { _, value in onReduceMotionChange(value) }
    }

    @ViewBuilder
    private var modalOverlay: some View {
        if let modal = model.modal {
            ZStack {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { model.dismissModal() }
                switch modal {
                case let .createCategory(token):
                    MacClippyCreateCategoryEditor { name, color in
                        model.createPinboard(name: name, color: color)
                        model.dismissModal()
                    } onCancel: {
                        model.dismissModal()
                    }
                    .id(token)
                case let .editLabel(recordID, initialLabel, token):
                    MacClippyEditLabelEditor(initialLabel: initialLabel) { result in
                        if case let .save(label) = result {
                            model.setLabel(for: recordID, label: label)
                        }
                        model.dismissModal()
                    } onCancel: {
                        model.dismissModal()
                    }
                    .id(token)
                case let .renameCategory(pinboardID, token):
                    Group {
                        if let pinboard = model.pinboards.first(where: { $0.id == pinboardID }) {
                            MacClippyRenameCategoryEditor(initialName: pinboard.name) { name in
                                model.renamePinboard(pinboard, to: name)
                                model.dismissModal()
                            } onCancel: {
                                model.dismissModal()
                            }
                        } else {
                            Color.clear.onAppear { model.dismissModal() }
                        }
                    }
                    .id(token)
                case let .confirmDeleteCategory(pinboardID, name, token):
                    Group {
                        if let pinboard = model.pinboards.first(where: { $0.id == pinboardID }) {
                            MacClippyConfirmDeleteCategoryEditor(categoryName: name) {
                                model.deletePinboard(pinboard)
                                model.dismissModal()
                            } onCancel: {
                                model.dismissModal()
                            }
                        } else {
                            Color.clear.onAppear { model.dismissModal() }
                        }
                    }
                    .id(token)
                }
            }
            .transition(.opacity)
            .animation(MacClippyMotion.animation(MacClippyMotion.contentAnimation, reduceMotion: reduceMotion), value: model.modal)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                // Plain magnifying-glass icon, no circular badge (reference).
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(MacClippyDockTheme.muted2Color)
                TextField("Search clipboard...", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                    .foregroundStyle(MacClippyDockTheme.textColor)
                    .focused($isSearchFocused)
                    .onChange(of: isSearchFocused) { _, focused in
                        onSearchModeChange(focused)
                    }
                    .onTapGesture {
                        isSearchFocused = true
                        onSearchModeChange(true)
                    }
                    .onSubmit { model.reload() }
                    .onChange(of: model.query) { _, _ in model.scheduleReload() }
                    .help("Search clipboard history. Add clauses like type:text, app:name, tag:label, has:label, has:ocr, before:YYYY-MM-DD, after:YYYY-MM-DD.")
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        isSearchFocused = true
                        onSearchModeChange(true)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(MacClippyDockTheme.muted2Color)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .transition(.opacity)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(MacClippyDockTheme.panelStrongColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(
                        isSearchFocused ? MacClippyDockTheme.accentColor.opacity(0.32) : MacClippyDockTheme.lineColor,
                        lineWidth: 1
                    )
            }
            .overlay {
                if isSearchFocused {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(MacClippyDockTheme.accentSoftColor, lineWidth: 3)
                }
            }
            .scaleEffect(reduceMotion ? 1 : (isSearchFocused ? 1.005 : 1))
            .animation(MacClippyMotion.animation(MacClippyMotion.focusAnimation, reduceMotion: reduceMotion), value: isSearchFocused)
        }
    }

    private var filterPillRow: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    filterPill(
                        title: "All",
                        count: model.historyItems.count,
                        selected: model.selectedTab == .history
                    ) {
                        model.selectTab(.history)
                    }
                    ForEach(model.pinboards) { pinboard in
                        filterPill(
                            title: pinboard.name,
                            count: pinboard.items.count,
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
                        count: model.snippets.count,
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
                showAboutPanel()
            } label: {
                Image(systemName: "gearshape")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(hoveredGear ? MacClippyDockTheme.accentColor : MacClippyDockTheme.muted2Color)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(hoveredGear ? MacClippyDockTheme.cardColor.opacity(0.60) : MacClippyDockTheme.cardColor.opacity(0.50)))
            .circleBorder(hoveredGear ? MacClippyDockTheme.pillHoverBorder : MacClippyDockTheme.pillRestBorder)
            .contentShape(Circle())
            .onHover { hovering in hoveredGear = hovering }
            .help("Settings")
        }
    }

    // Keep the historical helper name to avoid changing the dock's call site.
    private func showAboutPanel() {
        onClose()
        DispatchQueue.main.asyncAfter(deadline: .now() + MacClippyMotion.exitDuration) {
            openSettings()
            DispatchQueue.main.async {
                MacClippySettingsWindowCoordinator.shared.bringToFront()
            }
        }
    }

    // +New as a standalone icon button, separated from the filter pills so
    // the tab row stays semantically pure (filters only). Instant hover.
    private var newCategoryButton: some View {
        Button {
            model.presentCreateCategory()
        } label: {
            Image(systemName: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(hoveredNewCategory ? MacClippyDockTheme.accentColor : MacClippyDockTheme.muted2Color)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .background(Circle().fill(hoveredNewCategory ? MacClippyDockTheme.cardColor.opacity(0.60) : MacClippyDockTheme.cardColor.opacity(0.50)))
        .circleBorder(hoveredNewCategory ? MacClippyDockTheme.pillHoverBorder : MacClippyDockTheme.pillRestBorder)
        .contentShape(Circle())
        .onHover { hovering in hoveredNewCategory = hovering }
        .help("Create category")
    }

    private func filterPill(
        title: String,
        count: Int,
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
            (selected ? (accentColor ?? MacClippyDockTheme.pillRestBorder) :
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
                if let countLabel = MacClippyDockCategoryRailPolicy.countLabel(for: count) {
                    Text(countLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(selected ? MacClippyDockTheme.mutedColor : MacClippyDockTheme.muted2Color)
                }
            }
            .foregroundStyle(isDropConfirmed || isDropTarget ? MacClippyDockTheme.textColor : (selected ? (accentColor ?? MacClippyDockTheme.textColor) : (isHovered ? MacClippyDockTheme.textColor : MacClippyDockTheme.mutedColor)))
            .padding(.horizontal, 10)
            // Use a fixed capsule shape for both fill and stroke so the border
            // is drawn as part of the shape, not an overlay that can be clipped
            // by the ScrollView or the row's vertical centering.
            .frame(height: 30)
            .background(Capsule().fill(fillColor))
            .overlay(
                Capsule()
                    .inset(by: MacClippyDockTheme.pillBorderInset)
                    .stroke(borderColor, lineWidth: isDropConfirmed ? 2.5 : (isDropTarget ? 2 : MacClippyDockTheme.pillBorderWidth))
            )
            // Keep the Button label's hit shape aligned with the visible
            // capsule. Without this, SwiftUI can use the text's intrinsic
            // bounds for drag/drop hit testing and leave the pill's empty
            // horizontal padding unable to receive a drop.
            .contentShape(Capsule())
            .shadow(color: .black.opacity(selected ? 0.05 : 0), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
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
        .animation(MacClippyMotion.animation(MacClippyMotion.contentAnimation, reduceMotion: reduceMotion), value: selected)
        .animation(MacClippyMotion.animation(MacClippyMotion.contentAnimation, reduceMotion: reduceMotion), value: isDropTarget)
        .animation(MacClippyMotion.animation(MacClippyMotion.contentAnimation, reduceMotion: reduceMotion), value: isDropConfirmed)
        .animation(MacClippyMotion.animation(MacClippyMotion.focusAnimation, reduceMotion: reduceMotion), value: isHovered)
    }

    private func handleDrop(_ providers: [NSItemProvider], on pinboard: MacClippyPinboardEntry) -> Bool {
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
                model.pin(recordID: recordID, to: pinboard)
                dropConfirmedPinboardID = pinboard.id
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(MacClippyMotion.dropConfirmationLifetime * 1_000_000_000))
                    guard dropConfirmedPinboardID == pinboard.id else { return }
                    dropConfirmedPinboardID = nil
                }
            }
        }
        return true
    }

    private func handleSnippetDrop(_ providers: [NSItemProvider]) -> Bool {
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
                model.createSnippet(from: recordID)
                dropConfirmedSnippets = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(MacClippyMotion.dropConfirmationLifetime * 1_000_000_000))
                    guard dropConfirmedSnippets else { return }
                    dropConfirmedSnippets = false
                }
            }
        }
        return true
    }

    private func actionFeedbackView(_ feedback: MacClippyDockActionFeedback) -> some View {
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

    @ViewBuilder
    private var carousel: some View {
        carouselContent
            .transition(MacClippyMotion.contentTransition(reduceMotion: reduceMotion))
            .animation(MacClippyMotion.animation(MacClippyMotion.contentAnimation, reduceMotion: reduceMotion), value: model.selectedTab)
    }

    @ViewBuilder
    private var carouselContent: some View {
        let visibleItems = model.visibleItems
        let visibleSnippets = model.visibleSnippets
        if model.isLoading && visibleItems.isEmpty && visibleSnippets.isEmpty {
            ProgressView()
                .controlSize(.small)
                .tint(MacClippyDockTheme.accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = model.errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MacClippyDockTheme.accentColor)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(MacClippyDockTheme.mutedColor)
                    .multilineTextAlignment(.center)
                Button("Retry", action: { model.reload() })
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.selectedTab == .snippets {
            snippetCarousel
        } else if visibleItems.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.title3)
                    .foregroundStyle(MacClippyDockTheme.muted2Color)
                Text(emptyTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MacClippyDockTheme.textColor)
                Text(emptySubtitle)
                    .font(.caption)
                    .foregroundStyle(MacClippyDockTheme.mutedColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let visibleItemIDs = visibleItems.map(\.id)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: MacClippyDockCardMetrics.gap) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            card(item, index: index)
                                .id(item.id)
                                .transition(MacClippyMotion.cardListTransition(reduceMotion: reduceMotion))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, MacClippyDockCardMetrics.carouselVerticalPadding)
                }
                // Only keyboard/preview navigation follows the focused card.
                // Pointer selection leaves the carousel at its current scroll
                // position so clicking never recenters or reorders the list.
                .onChange(of: model.focusFollowRequestID) { _, _ in
                    guard let targetID = model.focusFollowTargetID,
                          visibleItems.contains(where: { $0.id == targetID }) else { return }
                    if reduceMotion {
                        proxy.scrollTo(targetID, anchor: .center)
                    } else {
                        withAnimation(MacClippyMotion.focusFollowSpring) {
                            proxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                }
                .animation(
                    MacClippyMotion.animation(MacClippyMotion.contentAnimation, reduceMotion: reduceMotion),
                    value: visibleItemIDs
                )
            }
            // Constrain the horizontal carousel to the compact card height plus
            // its vertical scroll padding so it never stretches to fill the
            // panel vertically and leaves a large blank gap below the cards.
            .frame(height: MacClippyDockCardMetrics.carouselHeight)
        }
    }

    private var snippetCarousel: some View {
        let visibleSnippets = model.visibleSnippets
        let visibleSnippetIDs = visibleSnippets.map(\.id)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: MacClippyDockCardMetrics.gap) {
                    snippetAddCard

                    if visibleSnippets.isEmpty, !model.snippets.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.title3)
                                .foregroundStyle(MacClippyDockTheme.muted2Color)
                            Text("No matching snippets")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(MacClippyDockTheme.textColor)
                            Text("Try a different search.")
                                .font(.caption)
                                .foregroundStyle(MacClippyDockTheme.mutedColor)
                        }
                        .frame(width: MacClippyDockCardMetrics.width, height: MacClippyDockCardMetrics.height)
                    } else {
                        ForEach(Array(visibleSnippets.enumerated()), id: \.element.id) { index, snippet in
                            snippetCard(snippet, index: index)
                                .id(snippet.id)
                                .transition(MacClippyMotion.cardListTransition(reduceMotion: reduceMotion))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, MacClippyDockCardMetrics.carouselVerticalPadding)
            }
            // Same keyboard/preview-only focus-follow behavior as the
            // clipboard carousel; pointer selection never recenters it.
            .onChange(of: model.focusFollowRequestID) { _, _ in
                guard let targetID = model.focusFollowTargetID,
                      visibleSnippets.contains(where: { $0.id == targetID }) else { return }
                if reduceMotion {
                    proxy.scrollTo(targetID, anchor: .center)
                } else {
                    withAnimation(MacClippyMotion.focusFollowSpring) {
                        proxy.scrollTo(targetID, anchor: .center)
                    }
                }
            }
            .animation(
                MacClippyMotion.animation(MacClippyMotion.contentAnimation, reduceMotion: reduceMotion),
                value: visibleSnippetIDs
            )
        }
        // Keep the snippet carousel the same compact height as the clipboard
        // carousel, including when the add card is the only card.
        .frame(height: MacClippyDockCardMetrics.carouselHeight)
    }

    private var snippetAddCard: some View {
        Button {
            onCreateSnippet()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(MacClippyDockTheme.accentColor)
                    .frame(width: 42, height: 42)
                    .background(MacClippyDockTheme.accentSoftColor, in: Circle())
                Text("Add snippet")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MacClippyDockTheme.textColor)
                Text("Create reusable text")
                    .font(.caption)
                    .foregroundStyle(MacClippyDockTheme.mutedColor)
            }
            .frame(width: MacClippyDockCardMetrics.width, height: MacClippyDockCardMetrics.height)
            .contentShape(RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous))
            .background(MacClippyDockTheme.cardColor, in: RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous)
                    .stroke(
                        MacClippyDockTheme.accentColor.opacity(0.65),
                        style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add snippet")
        .accessibilityHint("Create a reusable text snippet")
    }

    private func snippetCard(_ snippet: MacClippySnippetEntry, index: Int) -> some View {
        let isFocused = index == model.focusedIndex
        let isSelected = false
        let isElevated = isFocused || isSelected

        return Button {
            handleCardClick(clickCount: 1, modifiers: currentModifierFlags(), focus: { model.focus(snippet) })
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ZStack {
                            Image(systemName: "text.quote")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(MacClippyDockTheme.accentColor)
                        }
                        .frame(width: 28, height: 28)
                        .background(MacClippyDockTheme.accentSoftColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(MacClippyDockTheme.accentColor.opacity(0.45), lineWidth: 1)
                        )
                        Text(snippet.name)
                            .font(.system(size: MacClippyDockCardMetrics.contentFontSize, weight: .semibold))
                            .foregroundStyle(MacClippyDockTheme.textColor)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if index < 9 {
                            Text("⌘\(index + 1)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(MacClippyDockTheme.muted2Color)
                        }
                    }

                    if let trigger = snippet.trigger, !trigger.isEmpty {
                        Text(trigger)
                            .font(.system(size: MacClippyDockCardMetrics.contentFontSize, weight: .regular, design: .monospaced))
                            .foregroundStyle(MacClippyDockTheme.accentColor.opacity(0.9))
                            .lineLimit(1)
                    }
                }

                // Subtle divider below the card header, matching clipboard cards.
                Rectangle()
                    .fill(MacClippyDockTheme.lineColor)
                    .frame(height: 1)

                Text(snippet.preview.isEmpty ? "(empty)" : snippet.preview)
                    .font(MacClippyDockCardMetrics.contentFont)
                    .foregroundStyle(MacClippyDockTheme.textColor)
                    .lineSpacing(1)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(MacClippyDockCardMetrics.padding)
            .frame(width: MacClippyDockCardMetrics.width, height: MacClippyDockCardMetrics.height, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous))
            // Snippet cards use the stable opaque content surface (cardColor,
            // or cardHoverColor when elevated) per design.md — no gradient or
            // decorative color. The system accent stays on the snippet icon.
            .background(
                MacClippyDockTheme.snippetCardBackground(elevated: isElevated)
            )
            .overlay {
                RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous)
                    .stroke(
                        isSelected ? MacClippyDockTheme.accentColor.opacity(0.95) : (isFocused ? MacClippyDockTheme.accentColor.opacity(0.85) : MacClippyDockTheme.lineColor),
                        lineWidth: isSelected ? 2 : (isFocused ? 2 : 1)
                    )
            }
            .shadow(color: .black.opacity(isElevated ? 0.10 : 0.06), radius: isElevated ? 14 : 10, y: 4)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            handleCardClick(clickCount: 2, modifiers: currentModifierFlags(), focus: { model.focus(snippet) })
        })
        .contextMenu {
            snippetContextMenu(snippet)
        }
        .foregroundStyle(MacClippyDockTheme.textColor)
        // Keep the card grid fixed-size when focus changes. Selection is
        // communicated by the border and shadow rather than enlarging one
        // card relative to its neighbors.
        .animation(MacClippyMotion.animation(MacClippyMotion.focusAnimation, reduceMotion: reduceMotion), value: isFocused)
        .modifier(MacClippyCardHoverModifier(enabled: !model.isPreviewVisible, reduceMotion: reduceMotion))
        .accessibilityLabel("Snippet \(snippet.name): \(snippet.preview)")
        .accessibilityAction(named: "Paste") {
            focusCard()
            model.focus(snippet)
            model.pasteFocused(completion: onClose)
        }
        .accessibilityAction(named: "Copy") {
            focusCard()
            model.focus(snippet)
            model.copyFocused()
        }
        .accessibilityAction(named: "Delete") {
            focusCard()
            model.focus(snippet)
            model.deleteFocused()
        }
    }

    // Count how many consecutive identical-preview records follow the card at
    // `index` (inclusive of itself). Returns 1 when there is no run, so a badge
    // is only shown when run > 1. Text-only: images/files dedup by preview text
    // which is already the store's normalized preview.
    private func card(_ item: MacClippyHistoryEntry, index: Int) -> some View {
        let source = MacClippySourceAppResolver.presentation(for: item.meta.sourceAppBundleID)
        let isFocused = index == model.focusedIndex
        let isSelected = model.isSelected(item.id)
        // Preview focus is the single active visual target while the preview is
        // open. Selection remains available through the checkmark, but it must
        // not leave a second card with an orange border/glow as arrows move.
        let isActiveHighlight = MacClippyDockCardHighlightPolicy.isActive(
            isFocused: isFocused,
            isSelected: isSelected,
            isPreviewVisible: model.isPreviewVisible
        )
        let activeBorder = isActiveHighlight
        // Consecutive-duplicate count: O(1) lookup into the precomputed map so
        // a focus change never triggers an O(n²) rescan across all cards.
        let dedupRun = model.dedupRunCounts[item.id] ?? 1
        let isElevated = isFocused

        return Button {
            handleCardClick(
                clickCount: 1,
                modifiers: currentModifierFlags(),
                focus: { model.focusAndSelect(item) },
                selection: { [weak model] action in
                    guard let model else { return }
                    let clickedIndex = model.visibleItems.firstIndex(where: { $0.id == item.id }) ?? index
                    switch action {
                    case .focus:
                        model.focusSelection(at: clickedIndex)
                    case .toggle:
                        model.toggleSelection(at: clickedIndex)
                    case .extendRange:
                        model.extendRange(to: clickedIndex)
                    case .copy:
                        break
                    }
                }
            )
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // Paste-style metadata row: one quiet line above the content.
                // Source identity comes from the real icon; count and time
                // stay secondary instead of becoming nested badges.
                HStack(spacing: 9) {
                    sourceIcon(source, size: 36)
                    Text(source.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MacClippyDockTheme.textColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    if dedupRun > 1 {
                        Text("×\(dedupRun)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color(nsColor: source.accent))
                    }
                    if let timestamp = MacClippyDockTimestampPolicy.relativeLabel(for: item.meta.modified) {
                        Text(timestamp)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(MacClippyDockTheme.muted3Color)
                            .lineLimit(1)
                    } else if index < 9 {
                        Text("⌘\(index + 1)")
                            .font(.system(size: 11, weight: .regular).monospaced())
                            .foregroundStyle(MacClippyDockTheme.muted3Color)
                    }
                }
                .frame(height: 36)

                // Neutral card body with content-aware layout (code, URL,
                // files, image, or plain text).
                cardContent(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(MacClippyDockCardMetrics.padding)
            .frame(width: MacClippyDockCardMetrics.width, height: MacClippyDockCardMetrics.height, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous))
            // Keep the source tint subtle enough for text contrast, but apply
            // it to the full card so different source apps remain scannable.
            .background(MacClippyDockTheme.sourceCardBackground(accent: source.accent))
            .overlay {
                RoundedRectangle(cornerRadius: MacClippyDockCardMetrics.radius, style: .continuous)
                    .stroke(
                        activeBorder ? MacClippyDockTheme.accentColor.opacity(0.85) : MacClippyDockTheme.lineColor,
                        lineWidth: activeBorder ? 1.5 : 1
                    )
            }
            // Soft depth only; selection is communicated primarily by the ring.
                .shadow(
                color: model.isPreviewVisible
                    ? .clear
                    : .black.opacity(isElevated ? 0.08 : 0.05),
                radius: model.isPreviewVisible ? 0 : (isElevated ? 10 : 8),
                y: model.isPreviewVisible ? 0 : 3
            )
            // Animated checkmark badge overlapping the top-right corner when
            // this card is part of a multi-selection. Offset 3px out so it
            // reads as an overlapping badge, with a spring scale-in.
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(MacClippyDockTheme.accentColor)
                        .background(Circle().fill(MacClippyDockTheme.cardColor))
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        .offset(x: 3, y: -3)
                        .scaleEffect(reduceMotion ? 1 : 1)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0, anchor: .topTrailing).combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            // A double click is always a copy regardless of modifiers, so
            // Cmd/Shift double-click never pastes and never toggles.
            handleCardClick(clickCount: 2, modifiers: currentModifierFlags(), focus: { model.focusAndSelect(item) })
        })
        .contextMenu {
            itemContextMenu(item)
        }
        .onDrag {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { completion in
                completion(item.id.rawValue.data(using: .utf8), nil)
                return nil
            }
            return provider
        } preview: {
            Text(item.preview.isEmpty ? "Clipboard item" : item.preview)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(MacClippyDockTheme.textColor)
                .padding(.horizontal, 10)
                .frame(width: 180, height: 32, alignment: .leading)
                .background(MacClippyDockTheme.cardColor.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(0.72)
        }
        .foregroundStyle(MacClippyDockTheme.textColor)
        // Keep snippet and clipboard cards aligned to the same fixed grid;
        // focus is shown through the border and shadow instead of scale.
        .animation(MacClippyMotion.animation(MacClippyMotion.focusAnimation, reduceMotion: reduceMotion), value: isFocused)
        .animation(MacClippyMotion.animation(MacClippyMotion.contentAnimation, reduceMotion: reduceMotion), value: isSelected)
        .modifier(MacClippyCardHoverModifier(enabled: !model.isPreviewVisible, reduceMotion: reduceMotion))
        .accessibilityLabel(cardAccessibilityLabel(item, source: source))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Paste") {
            focusCard()
            model.focusAndSelect(item)
            model.pasteFocused(completion: onClose)
        }
        .accessibilityAction(named: "Copy") {
            focusCard()
            model.focusAndSelect(item)
            model.copyFocused()
        }
        .accessibilityAction(named: "Copy plain") {
            guard item.supportsPlainCopy else { return }
            focusCard()
            model.focusAndSelect(item)
            model.copyFocused(plain: true)
        }
        .accessibilityAction(named: "Edit Label") {
            model.focus(item)
            model.presentEditLabel(for: item)
        }
        .accessibilityAction(named: "Pin to list") {
            focusCard()
            model.focusAndSelect(item)
            if let firstPinboard = model.pinboards.first {
                model.togglePinFocused(in: firstPinboard.id)
            }
        }
        .accessibilityAction(named: "Delete") {
            focusCard()
            model.focusAndSelect(item)
            model.deleteFocused()
        }
    }

    // URL card body: retain the original URL text instead of replacing it with
    // a host/path summary. The fixed card height may visually truncate a long
    // URL, while Preview and paste continue to use the complete payload.
    @ViewBuilder
    private func urlCardBody(_ url: URL, item: MacClippyHistoryEntry) -> some View {
        let originalURL = item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 6) {
            Text(originalURL.isEmpty ? url.absoluteString : originalURL)
                .font(MacClippyDockCardMetrics.contentMonospacedFont)
                .foregroundStyle(MacClippyDockTheme.contentTextColor)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func cardFilesBody(_ item: MacClippyHistoryEntry) -> some View {
        // Content-first: the bounded file-name list is the card body. No type
        // badge/header is rendered (the doc.fill + "Files" header was removed);
        // accessibility labels still carry the full type/source context. When
        // file names are unavailable, fall back to the type metadata subtitle
        // (e.g. a count) or a meaningful "Files" label so the card is never
        // blank.
        let names = item.fileURLs.map(\.lastPathComponent)

        VStack(alignment: .leading, spacing: 2) {
            if names.isEmpty {
                Text(item.typeMetadataSubtitle ?? "\(label(for: item.contentKind))")
                    .font(MacClippyDockCardMetrics.contentFont)
                    .foregroundStyle(MacClippyDockTheme.contentTextColor)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            } else {
                ForEach(Array(names.prefix(3).enumerated()), id: \.offset) { _, name in
                    Text(name.isEmpty ? "(file)" : name)
                        .font(MacClippyDockCardMetrics.contentFont)
                        .foregroundStyle(MacClippyDockTheme.contentTextColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if names.count > 3 {
                    Text("+\(names.count - 3) more")
                        .font(MacClippyDockCardMetrics.contentFont)
                        .foregroundStyle(MacClippyDockTheme.contentMutedColor)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func cardImageBody(_ item: MacClippyHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail allowance sized to fit the compact 220pt card frame
            // while keeping the dimensions caption and OCR preview readable.
            MacClippyCardImageThumbnail(item: item, model: model)
                .frame(maxWidth: .infinity, maxHeight: 96, alignment: .top)
            if let subtitle = item.typeMetadataSubtitle {
                Text(subtitle)
                    .font(MacClippyDockCardMetrics.contentFont)
                    .foregroundStyle(MacClippyDockTheme.mutedColor)
            }
            if let ocrPreview = item.preview.isEmpty ? nil : item.preview,
               !ocrPreview.isEmpty {
                Text(ocrPreview)
                    .font(MacClippyDockCardMetrics.contentFont)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(MacClippyDockTheme.mutedColor)
            }
            Spacer(minLength: 0)
        }
    }

    // Accessibility label composes the custom label (when present) with the
    // type and source context so VoiceOver users hear the label first and
    // never lose the type/source context (the visual card drops type badges
    // and footer metadata, but accessibility preserves them). The preview text
    // is appended for text/html/rtf; for images the dimensions caption is
    // appended.
    private func cardAccessibilityLabel(_ item: MacClippyHistoryEntry, source: MacClippySourceAppPresentation) -> String {
        var parts: [String] = []
        if let customLabel = item.customLabel, !customLabel.isEmpty {
            parts.append(customLabel)
        }
        parts.append(label(for: item.contentKind))
        parts.append("from \(source.displayName)")
        if let timestamp = MacClippyDockTimestampPolicy.relativeLabel(for: item.meta.modified) {
            parts.append(timestamp)
        }
        switch item.contentKind {
        case .text, .html, .rtf:
            if !item.preview.isEmpty {
                let previewLimit = 240
                parts.append(String(item.preview.prefix(previewLimit)))
                if item.preview.count > previewLimit {
                    parts.append("preview shortened")
                }
            }
        case .image:
            if let dimensions = item.typeMetadataSubtitle {
                parts.append(dimensions)
            }
        case .files:
            if let subtitle = item.typeMetadataSubtitle {
                parts.append(subtitle)
            }
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func snippetContextMenu(_ snippet: MacClippySnippetEntry) -> some View {
        Button("Copy") {
            model.focus(snippet)
            model.copyFocused()
        }
        Button("Paste") {
            model.focus(snippet)
            model.pasteFocused(completion: onClose)
        }
        Divider()
        Button("Delete", role: .destructive) {
            model.focus(snippet)
            model.deleteFocused()
        }
    }

    @ViewBuilder
    private func pinboardContextMenu(_ pinboard: MacClippyPinboardEntry) -> some View {
        Button("Rename…") {
            model.presentRenameCategory(for: pinboard)
        }
        Menu("Change Color") {
            ForEach(MacClippyCategoryColorPolicy.palette, id: \.self) { color in
                Button {
                    model.setPinboardColor(pinboard, to: color)
                } label: {
                    Label {
                        Text(color)
                    } icon: {
                        Circle()
                            .fill(Color(macClippyHex: color))
                            .frame(width: 12, height: 12)
                    }
                }
                .accessibilityLabel("Change color to \(color)")
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            model.presentConfirmDeleteCategory(for: pinboard)
        }
    }

    @ViewBuilder
    private func itemContextMenu(_ item: MacClippyHistoryEntry) -> some View {
        Button("Copy") {
            model.focus(item)
            model.copyFocused()
        }
        if item.supportsPlainCopy {
            Button("Copy plain") {
                model.focus(item)
                model.copyFocused(plain: true)
            }
            // Transform submenu: shown only for text/html/rtf cards. Each
            // transform offers an explicit Copy transformed (keeps the dock
            // open, like Copy) and Paste transformed (closes the dock via the
            // existing onClose completion, like Paste). The transform engine
            // produces plain text; html/rtf are converted to plain text first.
            // Images/files are never offered here because the submenu is gated
            // on supportsPlainCopy, matching the Copy plain gating.
            Menu("Transform") {
                ForEach(TextTransform.allCases, id: \.self) { transform in
                    Menu(transform.displayName) {
                        Button("Copy transformed") {
                            model.focus(item)
                            model.copyFocused(transform: transform)
                        }
                        Button("Paste transformed") {
                            model.focus(item)
                            model.pasteFocused(transform: transform, completion: onClose)
                        }
                    }
                }
            }
        }
        Button("Paste") {
            model.focus(item)
            model.pasteFocused(completion: onClose)
        }
        Button("Edit Label…") {
            model.focus(item)
            model.presentEditLabel(for: item)
        }
        if !model.pinboards.isEmpty {
            Menu("Pin to list") {
                ForEach(model.pinboards) { pinboard in
                    Button {
                        model.focus(item)
                        model.togglePinFocused(in: pinboard.id)
                    } label: {
                        Label(
                            pinboard.name,
                            systemImage: model.isPinned(item.id, in: pinboard) ? "checkmark" : "pin"
                        )
                    }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            model.focus(item)
            model.deleteFocused()
        }
    }

    private func sourceIcon(_ source: MacClippySourceAppPresentation, size: CGFloat = 20) -> some View {
        // Real source app icon at the requested header size with rounded-md
        // corners, a hairline ring, and a micro shadow. The source accent
        // tints the fallback glyph.
        let corner: CGFloat = size > 20 ? 9 : 5
        return ZStack {
            if let icon = source.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(size > 20 ? .callout.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(Color(nsColor: source.accent))
            }
        }
        .frame(width: size, height: size)
        .background(Color(nsColor: source.accent).opacity(0.10), in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Color(nsColor: source.accent).opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
    }

    // Single content surface. Content-aware layout remains, but ordinary text,
    // URLs, files, and images no longer create a white card inside the card.
    @ViewBuilder
    private func cardContent(_ item: MacClippyHistoryEntry) -> some View {
        let classificationPreview = String(item.preview.prefix(2_000))
        let isCode = (item.contentKind == .text || item.contentKind == .html || item.contentKind == .rtf)
            && MacClippyDockURLPolicy.url(from: classificationPreview) == nil
            && MacClippyDockCodePolicy.isCode(classificationPreview)
        let isURL = MacClippyDockURLPolicy.url(from: classificationPreview) != nil

        VStack(alignment: .leading, spacing: 0) {
            // Custom label sits above the content when present.
            if let customLabel = item.customLabel, !customLabel.isEmpty {
                Text(customLabel)
                    .font(MacClippyDockCardMetrics.contentFont)
                    .foregroundStyle(MacClippyDockTheme.contentTextColor)
                    .lineLimit(2)
                    .padding(.bottom, 2)
            }

            Group {
                if item.contentKind == .files {
                    cardFilesBody(item)
                } else if item.contentKind == .image {
                    cardImageBody(item)
                } else if isURL, let url = MacClippyDockURLPolicy.url(from: classificationPreview) {
                    urlCardBody(url, item: item)
                } else if isCode {
                    codeCardBody(item)
                } else {
                    plainTextCardBody(item)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // Plain text is one continuous body. The card receives the full payload
    // from the runtime; only the fixed card geometry determines where SwiftUI
    // adds the tail ellipsis. Bound the render input so a very large paste
    // does not make the carousel expensive while still exceeding the number
    // of lines this card can display.
    @ViewBuilder
    private func plainTextCardBody(_ item: MacClippyHistoryEntry) -> some View {
        let text = item.preview.isEmpty ? "(empty)" : String(item.preview.prefix(2_000))

        Text(text)
            .font(MacClippyDockCardMetrics.contentFont)
            .foregroundStyle(MacClippyDockTheme.contentTextColor)
            .lineSpacing(1)
            .lineLimit(8)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // Code content stays monospaced; the card itself remains the single surface.
    @ViewBuilder
    private func codeCardBody(_ item: MacClippyHistoryEntry) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(String(item.preview.prefix(2_000)))
                .font(MacClippyDockCardMetrics.contentMonospacedFont)
                .foregroundStyle(MacClippyDockTheme.contentTextColor)
                .lineSpacing(1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollDisabled(true)
    }

    private var emptyTitle: String {
        if case .pinboard = model.selectedTab {
            return model.selectedPinboardName.map { "\($0) is empty" } ?? "Pinboard is empty"
        }
        return model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No clipboard history yet" : "No matches"
    }

    private var emptySubtitle: String {
        if case .pinboard = model.selectedTab {
            return "Pinned items will appear here."
        }
        return "Copied items will appear here."
    }

    private func iconName(for kind: ContentKind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .rtf: "textformat"
        case .image: "photo"
        case .files: "doc"
        }
    }

    private func label(for kind: ContentKind) -> String {
        switch kind {
        case .text: "Text"
        case .html: "HTML"
        case .rtf: "Rich text"
        case .image: "Image"
        case .files: "Files"
        }
    }

    private func focusCard() {
        isSearchFocused = false
        onEnterPickerMode()
    }

    // P1 pointer routing. A double click is ALWAYS a copy regardless of
    // modifiers, so Cmd/Shift double-click never pastes and never toggles a
    // selection; the panel closes after the copy succeeds. A plain single
    // click focuses one card and leaves the panel open; a Cmd single click
    // toggles the clicked card; a Shift single click extends the range from
    // the anchor. Snippets keep the existing single-focus path (no
    // multi-select in P1).
    private func handleCardClick(
        clickCount: Int,
        modifiers: NSEvent.ModifierFlags,
        focus: () -> Void,
        selection: ((MacClippyDockSelectionClickPolicy.Action) -> Void)? = nil
    ) {
        focusCard()
        let action = MacClippyDockSelectionClickPolicy.decision(clickCount: clickCount, modifiers: modifiers)
        switch action {
        case .copy:
            // The single-click Button action and the double-click simultaneous
            // gesture both arrive here; only a real double click should copy.
            // The click policy already guarantees .copy only for clickCount >= 2.
            focus()
            model.copyFocused(
                plain: false,
                completion: {
                    // The panel is about to disappear, so do not rely on the
                    // dock view's actionFeedback onChange to show this toast.
                    onCopyToast(MacClippyDockActionFeedback.copied(plain: false).title)
                    onClose()
                }
            )
        case .focus:
            focus()
        case .toggle, .extendRange:
            if let selection {
                selection(action)
            } else {
                // No selection router (snippets): fall back to plain focus so
                // a Cmd/Shift click on a snippet still focuses it instead of
                // being a silent no-op.
                focus()
            }
        }
    }

    // Helper to read the current global modifier flags at click time. SwiftUI
    // Button actions do not carry modifiers, so we read NSEvent's current
    // state. This is the same mechanism AppKit menus use to detect option-
    // clicks.
    private func currentModifierFlags() -> NSEvent.ModifierFlags {
        NSEvent.modifierFlags.intersection([.command, .shift, .option, .control])
    }

}

// P2a: bounded async image thumbnail for image cards. Loads the image bytes
// through the existing model.loadPreview seam (the same path the space-preview
// uses) so no extra body read happens on the main thread during card render.
// The thumbnail is bounded to the card's available image area and uses
// scaledToFit so the whole image is visible without resizing the card. The
// .task(id:) reloads when the card's record id changes (e.g. after a reload),
// and the completion checks that identity because callback-based preview work
// cannot be cancelled once queued. No AppKit Sendable wrappers are introduced:
// the loaded Data is turned into an NSImage on the main thread inside the
// SwiftUI body, which is the existing pattern used by MacClippyDockPreviewView.
private struct MacClippyCardImageThumbnail: View {
    let item: MacClippyHistoryEntry
    @ObservedObject var model: MacClippyDockModel

    @State private var image: NSImage?
    @State private var loadedItemID: RecordID?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .task(id: item.id) {
            // Only image records need a thumbnail; for any other kind the body
            // does not call this view, but guard anyway so a misuse is a no-op
            // instead of a wasted preview load.
            guard item.contentKind == .image else { return }
            let itemID = item.id
            loadedItemID = itemID
            image = nil
            model.loadImageThumbnail(for: itemID) { result in
                // Preview work is callback-based, so task cancellation alone
                // cannot stop a completion already queued on the main actor.
                // Ignore a completion for a card identity that has since been
                // recycled for another record.
                guard loadedItemID == itemID else { return }
                image = result.flatMap(NSImage.init(data:))
            }
        }
    }
}

// P2a: inline custom-label editor. Presented from a clipboard card context
// menu (and the focused-card Edit Label accessibility action). The text field
// is prefilled with the card's current trimmed label (empty when none is
// stored). Save (defaultAction / Return) trims the entered text and returns
// .save; a blank trimmed value is a valid clear. Cancel (cancelAction / Esc)
// returns .cancel without touching the store. The editor never writes to the
// pasteboard, so it has no copy/paste side effects. The parent owns the actual
// model.setLabel call so this view stays free of runtime dependencies.
private struct MacClippyEditLabelEditor: View {
    enum Outcome {
        case save(label: String?)
        case cancel
    }

    let initialLabel: String?
    let onComplete: (Outcome) -> Void
    let onCancel: () -> Void

    @FocusState private var isFieldFocused: Bool
    @State private var text: String

    init(initialLabel: String?, onComplete: @escaping (Outcome) -> Void, onCancel: @escaping () -> Void) {
        self.initialLabel = initialLabel
        self.onComplete = onComplete
        self.onCancel = onCancel
        // Prefill with the current trimmed label so the user edits in place;
        // nil/blank becomes an empty field so Save clears the label.
        let trimmed = initialLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _text = State(initialValue: trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Label")
                .font(.headline)
            TextField("Label", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(save)
            Text("Leave blank to clear the label.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") {
                    onComplete(.cancel)
                    onCancel()
                }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(MacClippyDockTheme.panelStrongColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MacClippyDockTheme.lineColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .onAppear { isFieldFocused = true }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Blank clears the label: pass nil so the model/runtime normalizes to
        // a cleared stored label and rebuilds the index without the label term.
        onComplete(.save(label: trimmed.isEmpty ? nil : trimmed))
    }
}

struct MacClippyCreateSnippetEditor: View {
    let onCreate: (String, String?, String) -> Void
    let onCancel: () -> Void

    private enum Field {
        case name
        case trigger
        case body
    }

    @FocusState private var focusedField: Field?
    @State private var name = ""
    @State private var trigger = ""
    @State private var snippetBody = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New snippet")
                .font(.headline)
            Text("Save reusable text and optionally give it a ;trigger for automatic expansion.")
                .font(.caption)
                .foregroundStyle(MacClippyDockTheme.mutedColor)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .name)
                .onSubmit { focusedField = .trigger }

            VStack(alignment: .leading, spacing: 5) {
                TextField("Trigger (optional, e.g. ;email)", text: $trigger)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .trigger)
                    .onSubmit { focusedField = .body }
                Text("Leave blank if you only want to copy or paste it manually.")
                    .font(.caption2)
                    .foregroundStyle(MacClippyDockTheme.muted2Color)
            }

            TextEditor(text: $snippetBody)
                .font(.body)
                .focused($focusedField, equals: .body)
                .frame(height: 110)
                .padding(5)
                .background(MacClippyDockTheme.cardColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(MacClippyDockTheme.lineColor, lineWidth: 1)
                }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(28)
        .frame(width: 440, height: 410, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focusedField = .name }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !snippetBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        guard canCreate else { return }
        let normalizedTrigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        onCreate(
            name.trimmingCharacters(in: .whitespacesAndNewlines),
            normalizedTrigger.isEmpty ? nil : normalizedTrigger,
            snippetBody
        )
    }
}

private struct MacClippyCreateCategoryEditor: View {
    let onCreate: (String, String) -> Void
    let onCancel: () -> Void
    @FocusState private var isNameFocused: Bool
    @State private var name = ""
    @State private var selectedColor = MacClippyCategoryColorPolicy.palette[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New category")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(create)
            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    ForEach(MacClippyCategoryColorPolicy.palette, id: \.self) { color in
                        Button {
                            selectedColor = color
                        } label: {
                            Circle()
                                .fill(Color(macClippyHex: color))
                                .frame(width: 22, height: 22)
                                .overlay {
                                    Circle()
                                        .stroke(Color.primary.opacity(selectedColor == color ? 0.9 : 0), lineWidth: 2)
                                        .padding(-3)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose \(colorName(for: color))")
                        .accessibilityAddTraits(selectedColor == color ? .isSelected : [])
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 310)
        .background(MacClippyDockTheme.panelStrongColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MacClippyDockTheme.lineColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .onAppear {
            // Wait until the overlay is mounted in the existing Dock panel so
            // this field wins focus over the field that opened the modal.
            DispatchQueue.main.async { isNameFocused = true }
        }
    }

    private func create() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        onCreate(trimmedName, selectedColor)
    }

    private func colorName(for color: String) -> String {
        switch MacClippyCategoryColorPolicy.palette.firstIndex(of: color) {
        case 0: "blue"
        case 1: "purple"
        case 2: "orange"
        case 3: "teal"
        case 4: "ochre"
        case 5: "green"
        default: "custom color"
        }
    }
}

private struct MacClippyRenameCategoryEditor: View {
    let initialName: String
    let onRename: (String) -> Void
    let onCancel: () -> Void

    @FocusState private var isNameFocused: Bool
    @State private var name: String

    init(initialName: String, onRename: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.initialName = initialName
        self.onRename = onRename
        self.onCancel = onCancel
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename category")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(rename)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 310)
        .background(MacClippyDockTheme.panelStrongColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MacClippyDockTheme.lineColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .onAppear { isNameFocused = true }
    }

    private func rename() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        onRename(trimmedName)
    }
}

private struct MacClippyConfirmDeleteCategoryEditor: View {
    let categoryName: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete \"\(categoryName)\"?")
                .font(.headline)
            Text("The category will be removed, but its clipboard items will stay in All history.")
                .font(.body)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive, action: onConfirm)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(MacClippyDockTheme.panelStrongColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MacClippyDockTheme.lineColor, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
    }
}

private extension Color {
    init(macClippyHex value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard normalized.count == 6,
              let hex = UInt64(normalized, radix: 16) else {
            self = .accentColor
            return
        }
        self.init(
            nsColor: NSColor(
                calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        )
    }
}

// Multi-select action button with three visual tiers per design.md: primary
// (accent fill, the single most important action), destructive (semantic red
// text + red hover ring for Delete/Clear), and default (neutral capsule).
// Hover adds a subtle ring so every interactive surface has an indicator.
private struct SelectionBarButton: View {
    enum Emphasis { case `default`, primary, destructive }

    let title: String
    let systemImage: String
    let role: ButtonRole?
    let emphasis: Emphasis
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var isHovered = false

    init(_ title: String, systemImage: String, role: ButtonRole? = nil, emphasis: Emphasis = .default, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.emphasis = role == .destructive ? .destructive : emphasis
        self.action = action
    }

    var body: some View {
        let isDestructive = emphasis == .destructive
        let isPrimary = emphasis == .primary
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    isPrimary ? Color.white :
                    (isDestructive ? Color.red.opacity(0.9) : MacClippyDockTheme.textColor)
                )
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .frame(minHeight: 28)
                .background(
                    isPrimary
                        ? MacClippyDockTheme.accentColor
                        : MacClippyDockTheme.cardColor.opacity(isHovered ? 0.85 : 0.55),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .stroke(
                            isPrimary ? Color.clear :
                            (isDestructive ? Color.red.opacity(isHovered ? 0.7 : 0.35) :
                             (isHovered ? MacClippyDockTheme.accentColor.opacity(0.5) : MacClippyDockTheme.lineColor)),
                            lineWidth: isHovered ? 1.5 : 1
                        )
                )
                .shadow(color: isPrimary ? MacClippyDockTheme.accentColor.opacity(0.25) : .clear, radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
        .animation(
            MacClippyMotion.animation(MacClippyMotion.focusAnimation, reduceMotion: accessibilityReduceMotion),
            value: isHovered
        )
    }
}

private struct TopRoundedRectangle: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.minY),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + radius),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

// A screen-level toast for copy confirmations. Shown in its own
// floating panel so a double-click copy reads as a system indicator, not an
// in-dock overlay. Auto-dismissed by the controller after ~1.2s.
struct MacClippyCopyToastView: View {
    let title: String
    var showsShadow = true
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
            Text(title)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(MacClippyDockTheme.textColor)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .background(
            Capsule()
                .fill(MacClippyDockTheme.panelStrongColor)
                .shadow(
                    color: showsShadow ? .black.opacity(0.18) : .clear,
                    radius: showsShadow ? 16 : 0,
                    y: showsShadow ? 6 : 0
                )
        )
    }
}
