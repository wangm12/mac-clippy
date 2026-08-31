import AppKit
import CoreGraphics
import Foundation

import MacClippyCore
import MacClippyPlatform

struct MacClippyHistoryEntry: Identifiable, Sendable {
    let meta: ClipboardItemMeta
    let contentKind: ContentKind
    let preview: String
    let fileURLs: [URL]
    let imageDimensions: CGSize?
    let isRemoteClipboard: Bool

    init(
        meta: ClipboardItemMeta,
        contentKind: ContentKind,
        preview: String,
        fileURLs: [URL] = [],
        imageDimensions: CGSize? = nil,
        isRemoteClipboard: Bool = false
    ) {
        self.meta = meta
        self.contentKind = contentKind
        self.preview = preview
        self.fileURLs = fileURLs
        self.imageDimensions = imageDimensions
        self.isRemoteClipboard = isRemoteClipboard
    }

    func withRemoteClipboard(_ isRemoteClipboard: Bool) -> MacClippyHistoryEntry {
        guard isRemoteClipboard != self.isRemoteClipboard else { return self }
        return MacClippyHistoryEntry(
            meta: meta,
            contentKind: contentKind,
            preview: preview,
            fileURLs: fileURLs,
            imageDimensions: imageDimensions,
            isRemoteClipboard: isRemoteClipboard
        )
    }

    var id: RecordID { meta.id }
    var isPasteable: Bool {
        switch contentKind {
        case .text, .html, .rtf, .image, .files:
            true
        }
    }

    var supportsPlainCopy: Bool {
        switch contentKind {
        case .text, .html, .rtf: true
        case .image, .files: false
        }
    }

    var customLabel: String? {
        let trimmed = meta.customLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    var displayTitle: String {
        customLabel ?? preview
    }

    var typeMetadataSubtitle: String? {
        switch contentKind {
        case .files:
            if fileURLs.isEmpty { return nil }
            return MacClippyFilePresentation.title(fileCount: fileURLs.count)
        case .image:
            guard let dimensions = imageDimensions else { return nil }
            return "\(Int(dimensions.width))×\(Int(dimensions.height))"
        case .text, .html, .rtf:
            return nil
        }
    }
}

struct MacClippySnippetEntry: Identifiable, Sendable {
    private static let searchNameLimit = 512
    private static let searchTriggerLimit = 256
    private static let searchBodyLimit = 16_384
    private static let previewBodyLimit = 4_096

    let snippet: Snippet
    let normalizedSearchText: String
    let preview: String

    init(snippet: Snippet) {
        self.snippet = snippet
        let boundedBody = String(snippet.body.prefix(Self.previewBodyLimit))
        let normalizedPreview = boundedBody
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        preview = snippet.body.count > Self.previewBodyLimit
            ? normalizedPreview + " …"
            : normalizedPreview
        normalizedSearchText = [
            String(snippet.name.prefix(Self.searchNameLimit)),
            String((snippet.trigger ?? "").prefix(Self.searchTriggerLimit)),
            String(snippet.body.prefix(Self.searchBodyLimit))
        ]
        .joined(separator: "\n")
        .lowercased()
    }

    var id: RecordID { snippet.id }
    var name: String { snippet.name }
    var trigger: String? { snippet.trigger }
    var body: String { snippet.body }
}

struct MacClippyRuntimePreviewText: Sendable {
    let displayText: String
    let characterCount: Int
    let kind: MacClippyClipboardPresentationKind
}

// A rich-text preview is decoded once on the preview work queue and then only
// read on the main actor. NSAttributedString is not Sendable, so that single
// hand-off is expressed here instead of conforming all of Foundation's
// attributed strings module-wide.
// SAFETY: `attributed` is an immutable copy taken at construction, so no
// reference the producer still holds can mutate it after the box is sent.
struct MacClippyPreviewRichText: @unchecked Sendable {
    let attributed: NSAttributedString

    init(_ attributed: NSAttributedString) {
        self.attributed = attributed.copy() as? NSAttributedString
            ?? NSAttributedString(attributedString: attributed)
    }
}

enum MacClippyRuntimePreviewPayload: Sendable {
    case text(MacClippyRuntimePreviewText)
    case richText(MacClippyPreviewRichText, plain: String, characterCount: Int)
    case image(Data)
    case files([URL])
}

struct MacClippyItemRepresentationDetails: Identifiable, Sendable {
    let uti: String
    let payloadState: MacClippyClipboardRepresentationPayloadState
    let byteCount: Int
    let isAvailable: Bool

    var id: String { uti }
}

struct MacClippyItemDetails: Identifiable, Sendable {
    let id: RecordID
    let title: String
    let contentKind: ContentKind
    let sourceAppBundleID: String?
    let created: Date
    let modified: Date
    let frequency: Int
    let lastAccessed: Date?
    let customLabel: String?
    let ocrText: String?
    let preview: String
    let textContent: String?
    let textContentPreview: String?
    let fileURLs: [URL]
    let imageDimensions: CGSize?
    let pinboardNames: [String]
    let representations: [MacClippyItemRepresentationDetails]

    var isEditable: Bool {
        contentKind == .text || contentKind == .html || contentKind == .rtf
    }
}

final class MacClippyHistoryEntryCacheBox {
    let entry: MacClippyHistoryEntry

    init(_ entry: MacClippyHistoryEntry) {
        self.entry = entry
    }
}

struct MacClippyPinboardEntry: Identifiable, Sendable {
    let board: Pinboard
    let items: [MacClippyHistoryEntry]
    let itemCount: Int
    let nextPageToken: MacClippyPinboardSearchPageToken?

    init(
        board: Pinboard,
        items: [MacClippyHistoryEntry],
        itemCount: Int? = nil,
        nextPageToken: MacClippyPinboardSearchPageToken? = nil
    ) {
        self.board = board
        self.items = items
        self.itemCount = itemCount ?? board.itemIDs.count
        self.nextPageToken = nextPageToken
    }

    var id: RecordID { board.id }
    var name: String { board.name }
    var colorHex: String { MacClippyCategoryColorPolicy.color(for: board) }
}

struct MacClippyBatchDeleteResult: Sendable, Equatable {
    let deletedIDs: [RecordID]
    let missingIDs: [RecordID]
    let failedIDs: [RecordID]
}

struct MacClippyBatchPinResult: Sendable, Equatable {
    let boardName: String
    let pinnedIDs: [RecordID]
    let duplicateIDs: [RecordID]
    let missingIDs: [RecordID]
    let failedIDs: [RecordID]
}

enum MacClippyMultiPasteResult: Sendable, Equatable {
    case merged(injected: Bool)
    case mixed(
        supportedIDs: [RecordID],
        unsupportedIDs: [RecordID],
        unsupportedKinds: [MacClippyDockMultiPastePolicy.Kind]
    )
    case textUnavailable(
        availableIDs: [RecordID],
        unavailableIDs: [RecordID],
        unavailableKinds: [MacClippyDockMultiPastePolicy.Kind]
    )
}

enum MacClippyMultiCopyResult: Sendable, Equatable {
    case merged
    case mixed(
        supportedIDs: [RecordID],
        unsupportedIDs: [RecordID],
        unsupportedKinds: [MacClippyDockMultiPastePolicy.Kind]
    )
    case textUnavailable(
        availableIDs: [RecordID],
        unavailableIDs: [RecordID],
        unavailableKinds: [MacClippyDockMultiPastePolicy.Kind]
    )
}

enum MacClippyQueuePasteResult: Sendable, Equatable {
    case completed(
        injectedIDs: [RecordID],
        unavailableIDs: [RecordID],
        unavailableKinds: [MacClippyDockMultiPastePolicy.Kind]
    )
    case manualPasteRequired(
        injectedIDs: [RecordID],
        unavailableIDs: [RecordID],
        unavailableKinds: [MacClippyDockMultiPastePolicy.Kind],
        manualPasteRequiredID: RecordID,
        remainingIDs: [RecordID]
    )
}

typealias ContentKind = MacClippyContentKind

enum MacClippyUserFacingError {
    static let genericAction = "Could not complete the action. Try again."
    static let historyLoad = "Could not load clipboard history. Try again."
    static let itemLoad = "Could not load the selected item. Try again."
    static let itemSave = "Could not save the selected item. Try again."
    static let snippetTextOnly = "Only text clipboard items can become snippets."
}

enum MacClippySnippetCreationError: Error, Equatable {
    case unsupportedContent
    case invalidName
    case emptyBody
    case duplicateTrigger
}

struct MacClippyRetentionPreferencesSnapshot: Equatable {
    let maxItems: Int?
    let maxAgeDays: Int?
    let maxImageMegabytes: Int?
    let maxHistoryMegabytes: Int?

    init(defaults: UserDefaults) {
        maxItems = defaults.object(forKey: MacClippyRetentionPreferences.maxItemsKey) as? Int
        maxAgeDays = defaults.object(forKey: MacClippyRetentionPreferences.maxAgeDaysKey) as? Int
        maxImageMegabytes = defaults.object(forKey: MacClippyRetentionPreferences.maxImageMegabytesKey) as? Int
        maxHistoryMegabytes = defaults.object(forKey: MacClippyRetentionPreferences.maxHistoryMegabytesKey) as? Int
    }
}

struct MacClippyRuntimeLifecycleToken: Equatable, Sendable {
    let generation: UInt64
}

final class MacClippyStorageDegradedReasons: @unchecked Sendable {
    private let lock = NSLock()
    private var values = Set<String>()

    func contains(_ reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return values.contains(reason)
    }

    func insert(_ reason: String) {
        lock.lock()
        values.insert(reason)
        lock.unlock()
    }

    func remove(_ reason: String) {
        lock.lock()
        values.remove(reason)
        lock.unlock()
    }
}
