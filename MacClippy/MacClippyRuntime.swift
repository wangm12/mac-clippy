import AppKit
import ApplicationServices
import Foundation

import MacClippyCore
import MacClippyPlatform

struct MacClippyHistoryEntry: Identifiable, Sendable {
    let meta: ClipboardItemMeta
    let contentKind: ContentKind
    let preview: String
    // P2a: type-aware card content. files records carry their resolved URLs so
    // the card can show useful file metadata (count + names) without re-reading
    // the body on the main thread; image records carry their pixel dimensions
    // so the card can show a bounded thumbnail with a size caption. Both are
    // populated in entry(for:), which already reads the body under the store
    // lock, so no extra DB read is added.
    let fileURLs: [URL]
    let imageDimensions: CGSize?

    init(
        meta: ClipboardItemMeta,
        contentKind: ContentKind,
        preview: String,
        fileURLs: [URL] = [],
        imageDimensions: CGSize? = nil
    ) {
        self.meta = meta
        self.contentKind = contentKind
        self.preview = preview
        self.fileURLs = fileURLs
        self.imageDimensions = imageDimensions
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

    // P2a: a trimmed custom label set by the user, or nil when no label is
    // stored. The store already normalizes blank/whitespace-only to nil, so
    // a non-nil value here is always a meaningful label.
    var customLabel: String? {
        let trimmed = meta.customLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    // P2a: the prominent title shown at the top of a card. A custom label
    // wins when present; otherwise the existing type/source information is
    // surfaced via the card header so the card never loses the type/source
    // context. The card view composes the header from this and the source
    // resolver, so this only names the user-facing title text.
    var displayTitle: String {
        customLabel ?? preview
    }

    // P2a: a short, type-aware subtitle for the card body. Files surface their
    // count and first name; images surface their pixel dimensions; text/html/
    // rtf surface nothing extra (the readable preview text is the body). Used
    // by the card view alongside the readable preview so the card presents
    // useful file/image metadata without re-reading the body.
    var typeMetadataSubtitle: String? {
        switch contentKind {
        case .files:
            if fileURLs.isEmpty { return nil }
            if fileURLs.count == 1 {
                let name = fileURLs.first?.lastPathComponent
                return name?.isEmpty ?? true ? nil : name
            }
            return "\(fileURLs.count) files"
        case .image:
            guard let dimensions = imageDimensions else { return nil }
            return "\(Int(dimensions.width))×\(Int(dimensions.height))"
        case .text, .html, .rtf:
            return nil
        }
    }
}

struct MacClippySnippetEntry: Identifiable, Sendable {
    let snippet: Snippet

    var id: RecordID { snippet.id }
    var name: String { snippet.name }
    var trigger: String? { snippet.trigger }
    var body: String { snippet.body }
    var preview: String {
        body.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum MacClippyRuntimePreviewPayload: Sendable {
    case text(String)
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
    let fileURLs: [URL]
    let imageDimensions: CGSize?
    let pinboardNames: [String]
    let representations: [MacClippyItemRepresentationDetails]

    var isEditable: Bool {
        contentKind == .text || contentKind == .html || contentKind == .rtf
    }
}

private final class MacClippyHistoryEntryCacheBox {
    let entry: MacClippyHistoryEntry

    init(_ entry: MacClippyHistoryEntry) {
        self.entry = entry
    }
}

struct MacClippyPinboardEntry: Identifiable, Sendable {
    let board: Pinboard
    let items: [MacClippyHistoryEntry]

    var id: RecordID { board.id }
    var name: String { board.name }
    var colorHex: String { MacClippyCategoryColorPolicy.color(for: board) }
}

// P1 batch delete result. Lists the clipboard record IDs that were actually
// deleted (and were present), the IDs that were not found, and the IDs that
// were present but whose per-item delete raised an error (failedIDs). The
// caller reports partial results instead of silently dropping an item; a
// non-empty failedIDs means the dock must NOT report a complete success.
struct MacClippyBatchDeleteResult: Sendable, Equatable {
    let deletedIDs: [RecordID]
    let missingIDs: [RecordID]
    let failedIDs: [RecordID]
}

// P1 batch pin result. Lists the IDs newly pinned to the target board, the IDs
// that were already members (safe no-ops), the IDs that were not found, and
// the IDs that were present but whose per-item pin raised an error
// (failedIDs). `boardName` is included so the dock can show "Pinned N to
// <board>" feedback. A non-empty failedIDs means the dock must NOT report a
// complete success.
struct MacClippyBatchPinResult: Sendable, Equatable {
    let boardName: String
    let pinnedIDs: [RecordID]
    let duplicateIDs: [RecordID]
    let missingIDs: [RecordID]
    let failedIDs: [RecordID]
}

// P1 ordered multi-paste result. `.merged` is returned for a homogeneous
// text-compatible selection whose payloads all decoded (empty string is
// valid) and was merged and injected as one paste; `injected` is false when
// the injector required manual paste. `.mixed` is returned for a selection
// that contained at least one non-text-compatible record; the supported and
// unsupported IDs (and the unsupported kinds) are surfaced so the caller can
// report exactly what was not pasted. `.textUnavailable` is returned when at
// least one text-compatible record had an unavailable/undecodable payload
// (e.g. malformed RTF); the available and unavailable IDs (and the
// unavailable kinds) are surfaced and NO paste occurred, so a nil payload is
// never silently merged as an empty piece. The runtime never pastes a subset
// of a mixed or unavailable selection.
enum MacClippyMultiPasteResult: Sendable, Equatable {
    case merged(injected: Bool)
    case mixed(supportedIDs: [RecordID], unsupportedIDs: [RecordID], unsupportedKinds: [MacClippyDockMultiPastePolicy.Kind])
    case textUnavailable(availableIDs: [RecordID], unavailableIDs: [RecordID], unavailableKinds: [MacClippyDockMultiPastePolicy.Kind])
}

// P1 ordered multi-copy result. Mirrors MacClippyMultiPasteResult for the
// mixed/unavailable cases so the dock can show the same no-silent-data-loss
// feedback, but the merged case carries `prepared` (the pasteboard write
// result) instead of `injected` because Copy all never posts a paste
// keystroke. The runtime resolves the ordered selection through the same
// shared MacClippyDockMultiPastePolicy as pasteOrdered, then prepares the
// merged homogeneous text on the pasteboard without injecting any keyboard
// event. Copy never bumps frequency (matching the single copy(id:) path);
// only paste bumps frequency.
enum MacClippyMultiCopyResult: Sendable, Equatable {
    case merged(prepared: Bool)
    case mixed(supportedIDs: [RecordID], unsupportedIDs: [RecordID], unsupportedKinds: [MacClippyDockMultiPastePolicy.Kind])
    case textUnavailable(availableIDs: [RecordID], unavailableIDs: [RecordID], unavailableKinds: [MacClippyDockMultiPastePolicy.Kind])
}

// Mixed-content sequential queue paste result. Unlike the homogeneous-only
// pasteOrdered path (which merges one text payload and injects a single paste),
// pasteQueued processes the ordered selected IDs one at a time in visual order,
// injecting a separate Cmd+V per record so mixed selections (text + image +
// files) can each be consumed by the target app. Every record that produced
// pasteboard content and was injected is listed in injectedIDs in the order it
// was pasted; its frequency is bumped exactly once. A record that is missing,
// malformed, or cannot produce pasteboard content is reported explicitly in
// unavailableIDs with its known content kind (or .unsupported when the body
// cannot be read) in unavailableKinds, and the queue CONTINUES with the
// remaining IDs — nothing is silently skipped. If the injector returns
// .manualPasteRequired, the queue STOPS immediately because the current
// pasteboard item has not been consumed automatically: manualPasteRequiredID is
// the current ID and remainingIDs lists the current ID plus every not-yet-
// attempted ID in visual order; no remaining ID is claimed injected and no
// further events are posted. Ordering is deterministic: injectedIDs,
// unavailableIDs/unavailableKinds, and remainingIDs all follow the supplied
// visual order.
enum MacClippyQueuePasteResult: Sendable, Equatable {
    // Every record was either injected or explicitly reported unavailable. No
    // manual-paste stop occurred. injectedIDs are the records actually pasted
    // (frequency bumped), in injection order; unavailableIDs/unavailableKinds
    // are the records that could not produce pasteboard content, in visual
    // order. A full success has empty unavailable lists; a partial completion
    // has a non-empty unavailable list but no manualPasteRequiredID.
    case completed(
        injectedIDs: [RecordID],
        unavailableIDs: [RecordID],
        unavailableKinds: [MacClippyDockMultiPastePolicy.Kind]
    )
    // The injector returned .manualPasteRequired for manualPasteRequiredID, so
    // the queue stopped. remainingIDs is the current ID plus every not-yet-
    // attempted ID in visual order; none of them is claimed injected.
    // unavailableIDs/unavailableKinds carry any records that were reported
    // unavailable BEFORE the manual stop, in visual order. injectedIDs lists
    // the records successfully injected BEFORE the manual stop, in injection
    // order.
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

// The runtime is deliberately shared by the AppKit main actor, the dedicated
// capture queue, OCR tasks, and the observer queue. All mutable runtime state
// is either protected by `storeLock`, an owned serial queue, or an
// independently synchronized collaborator. Keep this annotation until the
// stores can be expressed as actors without changing the synchronous AppKit
// APIs; new cross-queue access must go through those boundaries.
// SAFETY: `storeLock` serializes synchronous store operations; `captureQueue`
// owns capture/retention work; the observer, snippet snapshot, sentinel, and
// diagnostics recorder each have their own lifecycle/synchronization boundary.
// `lifecycleLock` serializes start/stop/permission refresh so a stop cannot
// interleave between the running-state transition and observer/timer setup.
// `MacClippyRuntimeConcurrencyTests` exercises concurrent history/label access
// while this remains a synchronous AppKit-facing API.
final class MacClippyRuntime: @unchecked Sendable {
    private let clipboardStore: ClipboardStore
    private let searchStore: SearchStore
    private let pinboardStore: PinboardStore
    private let snippetStore: SnippetStore
    private let databases: [MacClippyDatabase]
    private let blobStore: BlobStore
    private let observer: PasteboardObserver
    private let snippetExpander: MacClippySnippetExpander
    private let snippetLookupSnapshot: MacClippySnippetLookupSnapshot
    private let historyEntryCache = NSCache<NSString, MacClippyHistoryEntryCacheBox>()
    private let storeLock = NSLock()
    // Shared sentinel so Mac Clippy's own copy/paste/snippet writes are
    // suppressed by the observer without filtering any external content.
    private let writeSentinel = MacClippyPasteboardWriteSentinel()
    // Shared injector that stamps every copy/paste/snippet write with the
    // sentinel so the observer can skip recapture of Mac Clippy's own writes.
    // Injectable so regression tests can assert Copy all prepares the
    // pasteboard without posting a paste keystroke; production and existing
    // tests use the default sentinel-bound injector.
    private let pasteInjector: MacClippyPasteInjector
    // Off-main queue for capture mapping, encryption, blob writes, and DB
    // persistence. The observer polls on its own queue and hands the change
    // here so the main thread never blocks on capture.
    private let captureQueue = DispatchQueue(
        label: "com.macallyouneed.macclippy.capture",
        qos: .userInitiated
    )
    private var retentionTimer: DispatchSourceTimer?
    private var defaultsObserver: NSObjectProtocol?
    private let usesRuntimeExclusionRules: Bool
    private var storageDegradedReasons = Set<String>()

    // `start`, `stop`, and permission-driven snippet changes touch AppKit
    // lifecycle resources outside `storeLock`. Keep their transition atomic
    // with respect to one another even when a caller tears down the runtime
    // from a different queue during shutdown.
    private let lifecycleLock = NSLock()
    private var running = false

    var isRunning: Bool {
        withStoreLock { running }
    }

    init(
        paths: MacClippyPaths? = nil,
        keychain: MacClippyKeychainBackend = MacClippySystemKeychain(),
        observer: PasteboardObserver? = nil,
        pasteInjector: MacClippyPasteInjector? = nil
    ) throws {
        let resolvedPaths: MacClippyPaths
        if let paths {
            resolvedPaths = paths
        } else {
            resolvedPaths = try MacClippyPaths()
        }

        let key = try MacClippyDeviceKey(keychain: keychain).deviceKey()
        let deviceID = DeviceID.generate()
        let clipboardDatabase = try MacClippyDatabase(url: resolvedPaths.clipboardDatabaseURL)
        let searchDatabase = try MacClippyDatabase(url: resolvedPaths.searchDatabaseURL)
        let pinboardDatabase = try MacClippyDatabase(url: resolvedPaths.pinboardDatabaseURL)
        let snippetDatabase = try MacClippyDatabase(url: resolvedPaths.snippetDatabaseURL)
        databases = [clipboardDatabase, searchDatabase, pinboardDatabase, snippetDatabase]

        clipboardStore = try ClipboardStore(database: clipboardDatabase, deviceKey: key, deviceID: deviceID)
        searchStore = try SearchStore(database: searchDatabase)
        pinboardStore = try PinboardStore(database: pinboardDatabase, deviceKey: key)
        let snippetStore = try SnippetStore(database: snippetDatabase, deviceKey: key)
        self.snippetStore = snippetStore
        let snippetLookupSnapshot = MacClippySnippetLookupSnapshot()
        self.snippetLookupSnapshot = snippetLookupSnapshot
        snippetLookupSnapshot.replace(with: try snippetStore.list())
        blobStore = try BlobStore(rootURL: resolvedPaths.blobsURL, key: key)
        // Wire the shared sentinel into the observer so Mac Clippy's own
        // copy/paste/snippet writes are suppressed. If the caller injects an
        // observer (tests), we respect it as-is and the sentinel only covers
        // the injector side, which is still enough to avoid recapture for any
        // observer that also consumes the sentinel.
        //
        // Production default: empty CaptureExclusionRules so every external
        // representation (concealed, transient, custom, unknown UTIs) is
        // captured. The legacy concealed/transient/app filtering is only
        // available via CaptureExclusionRules.legacyDefault() for callers
        // that explicitly opt in; the runtime never uses it.
        usesRuntimeExclusionRules = observer == nil
        if let observer {
            self.observer = observer
        } else {
            self.observer = PasteboardObserver(
                exclusionRules: MacClippyRetentionPreferences.exclusionRules(),
                writeSentinel: writeSentinel
            )
        }
        // Injectable injector: tests pass one that records posts so Copy all
        // can be asserted to never post a paste keystroke. Production and
        // existing tests use the default sentinel-bound injector built from
        // the shared writeSentinel.
        let injector = pasteInjector ?? MacClippyPasteInjector(writeSentinel: writeSentinel)
        self.pasteInjector = injector
        historyEntryCache.totalCostLimit = 64 * 1024 * 1024
        historyEntryCache.countLimit = 500
        snippetExpander = MacClippySnippetExpander(
            lookup: { snippetLookupSnapshot.body(for: $0) },
            injector: injector
        )
    }

    #if DEBUG
        func closeForTesting() {
            databases.forEach { try? $0.queue.close() }
        }
    #endif

    func start() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let shouldStart = withStoreLock { () -> Bool in
            guard !running else { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        // Off-main startup reconciliation: trim orphan blobs and FTS rows left
        // behind by a crash mid-capture. Best-effort; failures are logged and
        // never block capture from starting.
        captureQueue.async { [weak self] in
            self?.reconcileStorage()
            self?.enforceRetention()
        }
        let retentionTimer = DispatchSource.makeTimerSource(queue: captureQueue)
        retentionTimer.schedule(deadline: .now() + 3_600, repeating: 3_600)
        retentionTimer.setEventHandler { [weak self] in self?.enforceRetention() }
        self.retentionTimer = retentionTimer
        retentionTimer.resume()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            if self.usesRuntimeExclusionRules {
                self.observer.updateExclusionRules(MacClippyRetentionPreferences.exclusionRules())
                self.observer.setCapturePaused(
                    UserDefaults.standard.bool(forKey: MacClippyRetentionPreferences.privacyPauseKey)
                )
            }
            self.captureQueue.async {
                self.enforceRetention()
            }
        }
        if usesRuntimeExclusionRules {
            observer.updateExclusionRules(MacClippyRetentionPreferences.exclusionRules())
            observer.setCapturePaused(UserDefaults.standard.bool(forKey: MacClippyRetentionPreferences.privacyPauseKey))
        }
        observer.start { [weak self] change in
            // Hand the change to the capture queue so mapping, encryption, and
            // DB writes never block the observer's poll loop or the main
            // thread.
            self?.captureQueue.async {
                self?.capture(change)
            }
        }
        _ = snippetExpander.start()
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        observer.stop()
        snippetExpander.stop()
        retentionTimer?.setEventHandler {}
        retentionTimer?.cancel()
        retentionTimer = nil
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
            self.defaultsObserver = nil
        }
        withStoreLock { running = false }
    }

    func refreshPermissionDependentFeatures() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard withStoreLock({ running }) else { return }
        if AXIsProcessTrusted() {
            _ = snippetExpander.start()
        } else {
            snippetExpander.stop()
        }
    }

    /// Rebuilds the clipboard FTS index from encrypted records. This is an
    /// explicit repair action rather than a startup side effect: every body
    /// must be decrypted, so the operation stays off the UI path and can be
    /// retried after a transient database or keychain failure.
    @discardableResult
    func repairSearchIndex(shouldCancel: () -> Bool = { false }) throws -> MacClippySearchRepairReport {
        try withStoreLock {
            var failedDocuments = 0
            let documents = try clipboardStore.list(limit: .max).compactMap { meta -> MacClippySearchDocument? in
                if shouldCancel() { throw MacClippySearchRepairError.cancelled }
                guard let body = try? clipboardStore.body(for: meta.id) else {
                    failedDocuments += 1
                    return nil
                }
                let text = Self.searchableIndexText(for: body, ocrText: meta.ocrText, label: meta.customLabel)
                return MacClippySearchDocument(id: meta.id, text: text)
            }
            let rebuilt = try searchStore.rebuild(documents: documents, shouldCancel: shouldCancel)
            if failedDocuments == 0 {
                try searchStore.clearRepairNeeded()
                storageDegradedReasons.remove("fts-repair-needed")
            } else {
                try searchStore.markRepairNeeded()
                storageDegradedReasons.insert("fts-repair-needed")
            }
            return MacClippySearchRepairReport(
                documentsWritten: rebuilt.documentsWritten,
                skippedEmptyDocuments: rebuilt.skippedEmptyDocuments,
                failedDocuments: failedDocuments
            )
        }
    }

    func storageHealth() -> [String: MacClippyDatabaseHealthReport] {
        withStoreLock {
            storageHealthLocked()
        }
    }

    func diagnosticsStorageSnapshot() -> MacClippyDiagnosticsStorageSnapshot {
        withStoreLock {
            let health = storageHealthLocked()
            return MacClippyDiagnosticsStorageSnapshot(
                databaseHealth: health,
                databaseRowCounts: [
                    "clipboard": clipboardStore.databaseRowCount() ?? 0,
                    "search": searchStore.databaseRowCount() ?? 0,
                    "pinboards": pinboardStore.databaseRowCount() ?? 0,
                    "snippets": snippetStore.databaseRowCount() ?? 0
                ]
            )
        }
    }

    func history(
        limit: Int,
        query: String,
        shouldCancel: () -> Bool = { false }
    ) throws -> [MacClippyHistoryEntry] {
        try measureDiagnosticMetric("search_history") {
            try withStoreLock {
                guard !shouldCancel() else { return [] }
                let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedQuery.isEmpty {
                    let metas = try clipboardStore.list(limit: limit)
                    var entries: [MacClippyHistoryEntry] = []
                    entries.reserveCapacity(metas.count)
                    for meta in metas {
                        guard !shouldCancel() else { return entries }
                        if let entry = entry(for: meta) {
                            entries.append(entry)
                        }
                    }
                    return entries
                }

                // P2b: parse the structured search grammar. Bare terms keep the
                // existing FTS behavior; structured clauses (type/app/tag/label/
                // has/before/after) are ANDed predicates evaluated against the
                // record's metadata. Unknown or malformed clauses degrade to bare
                // free-text terms so the query narrows via FTS instead of
                // broadening.
                let parsed = MacClippySearchGrammar.parse(trimmedQuery)

                // No structured clauses: preserve the existing FTS-only path so
                // bare-term search behavior (ranking, snippet preview) is
                // unchanged.
                if !parsed.hasStructuredClauses {
                    let ftsQuery = parsed.bareTerms.joined(separator: " ")
                    let hits = try searchStore.search(query: ftsQuery, limit: limit)
                    guard !shouldCancel() else { return [] }
                    return try historyEntriesFromHits(hits, shouldCancel: shouldCancel)
                }

                let needsKind = parsed.clauses.contains { if case .type = $0 { return true }; return false }
                let requestedKinds = parsed.clauses.compactMap { clause -> MacClippyContentKind? in
                    if case let .type(kind) = clause { return kind }
                    return nil
                }
                if Set(requestedKinds).count > 1 {
                    return []
                }
                let requestedKind = requestedKinds.first

                // Structured-only query (no bare terms): the FTS index cannot
                // help because there is nothing to match against. Fetch every
                // meta so the predicate has the full candidate set, then apply
                // the predicate and take `limit`. This is what makes
                // structured-only queries work AND fill the 16-card result limit
                // instead of underfilling by filtering only after a 16-row FTS
                // query.
                if parsed.isStructuredOnly {
                    let metas = try clipboardStore.list(
                        limit: .max,
                        filter: metadataFilter(for: parsed, contentKind: requestedKind)
                    )
                    var collected: [MacClippyHistoryEntry] = []
                    collected.reserveCapacity(min(metas.count, max(0, limit)))
                    let knownKinds = requestedKind.map { kind in
                        Dictionary(uniqueKeysWithValues: metas.map { ($0.id, kind) })
                    } ?? [:]
                    for meta in metas {
                        guard !shouldCancel() else { return collected }
                        guard collected.count < limit else { break }
                        let record = searchRecord(for: meta, needsKind: needsKind, knownKinds: knownKinds)
                        if MacClippySearchGrammar.matches(parsed, record: record),
                           let entry = entry(for: meta) {
                            collected.append(entry)
                        }
                    }
                    return collected
                }

                // Bare + structured: FTS supplies the candidates in rank order and
                // the structured predicate then narrows them. A single fixed pool
                // can underfill: a valid structured match can exist past the pool,
                // so the query would return fewer than `limit` even though more
                // matches exist. Instead, page through the FTS result set in
                // bounded pages (preserving rank/snippet order) until either enough
                // matches have been collected or the FTS result set is exhausted.
                // Each page stays bounded and off the main thread (history is
                // already called on the dock work queue); there is no arbitrary
                // global candidate cap.
                let boundedLimit = max(0, limit)
                if boundedLimit == 0 {
                    return []
                }
                let ftsQuery = parsed.bareTerms.joined(separator: " ")
                var collected: [MacClippyHistoryEntry] = []
                collected.reserveCapacity(boundedLimit)
                var pageOffset = 0
                while collected.count < boundedLimit {
                    guard !shouldCancel() else { return [] }
                    let remaining = boundedLimit - collected.count
                    // Page size is bounded: enough to fill the remaining slots a
                    // few times over so a typical query needs very few round trips,
                    // without ever loading the whole index in one query.
                    let pageSize = max(remaining * 4, 64)
                    let hits = try searchStore.search(query: ftsQuery, limit: pageSize, offset: pageOffset)
                    guard !hits.isEmpty else { break }
                    guard !shouldCancel() else { return [] }
                    let metas = try clipboardStore.metas(for: hits.map(\.id))
                    let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
                    let knownKinds = needsKind ? try clipboardStore.contentKinds(for: hits.map(\.id)) : [:]
                    for hit in hits {
                        guard collected.count < boundedLimit else { break }
                        guard let meta = metasByID[hit.id] else { continue }
                        let record = searchRecord(for: meta, needsKind: needsKind, knownKinds: knownKinds)
                        guard MacClippySearchGrammar.matches(parsed, record: record) else { continue }
                        guard let entry = entry(for: meta) else { continue }
                        // Preserve the type-aware file/image metadata from entry(for:)
                        // so a search result card shows the same file names / image
                        // dimensions as a history card; only the preview text is
                        // replaced with the FTS snippet.
                        collected.append(
                            MacClippyHistoryEntry(
                                meta: meta,
                                contentKind: entry.contentKind,
                                preview: hit.snippet,
                                fileURLs: entry.fileURLs,
                                imageDimensions: entry.imageDimensions
                            )
                        )
                    } 
                    // A short page means the FTS result set is exhausted; stop
                    // instead of issuing another (empty) round trip.
                    if hits.count < pageSize { break }
                    pageOffset += hits.count
                }
                return collected
            }
        }
    }

    private func metadataFilter(
        for query: MacClippySearchGrammar.Query,
        contentKind: MacClippyContentKind?
    ) -> MacClippyClipboardMetadataFilter {
        var filter = MacClippyClipboardMetadataFilter(contentKind: contentKind)
        for clause in query.clauses {
            switch clause {
            case let .app(value):
                filter.sourceAppContains.append(value)
            case let .label(value):
                filter.labelContains.append(value)
            case .hasLabel:
                filter.requiresLabel = true
            case .hasOCR:
                filter.requiresOCR = true
            case let .before(date):
                filter.modifiedBefore.append(date)
            case let .after(date):
                filter.modifiedAfter.append(date)
            case .bare, .type:
                break
            }
        }
        return filter
    }

    // P2b: resolve FTS hits to history entries, preserving the existing
    // snippet-as-preview behavior for bare-term search. Shared by the
    // bare-only path so the structured integration does not change how a
    // pure bare query is rendered.
    private func historyEntriesFromHits(
        _ hits: [SearchHit],
        shouldCancel: () -> Bool = { false }
    ) throws -> [MacClippyHistoryEntry] {
        let metas = try clipboardStore.metas(for: hits.map(\.id))
        let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
        var entries: [MacClippyHistoryEntry] = []
        entries.reserveCapacity(hits.count)
        for hit in hits {
            guard !shouldCancel() else { return [] }
            guard let meta = metasByID[hit.id], let entry = entry(for: meta) else { continue }
            entries.append(MacClippyHistoryEntry(
                meta: meta,
                contentKind: entry.contentKind,
                preview: hit.snippet,
                fileURLs: entry.fileURLs,
                imageDimensions: entry.imageDimensions
            ))
        }
        return entries
    }

    // P2b: build a SearchRecord for a meta. The predicate needs contentKind
    // only when the query has a type: clause; otherwise we avoid the body
    // read entirely so structured-only queries that filter on app/label/
    // has/before/after stay off the body-decryption path. When a kind is
    // needed, the body read reuses the same clipboardStore.body(for:) used
    // by entry(for:), so no new decryption surface is introduced.
    private func searchRecord(
        for meta: ClipboardItemMeta,
        needsKind: Bool,
        knownKinds: [RecordID: MacClippyContentKind] = [:]
    ) -> MacClippySearchGrammar.SearchRecord {
        let kind: MacClippyContentKind
        if needsKind {
            kind = knownKinds[meta.id] ?? (try? clipboardStore.body(for: meta.id))?.contentKind ?? .text
        } else {
            kind = .text
        }
        return MacClippySearchGrammar.SearchRecord(meta: meta, contentKind: kind)
    }

    func snippets() throws -> [MacClippySnippetEntry] {
        try withStoreLock {
            let snippets = try snippetStore.list()
            snippetLookupSnapshot.replace(with: snippets)
            return snippets.map { MacClippySnippetEntry(snippet: $0) }
        }
    }

    func createSnippet(from recordID: RecordID) throws -> MacClippySnippetEntry {
        try withStoreLock {
            let record = try clipboardStore.body(for: recordID)
            guard let body = MacClippyClipboardText.plainText(from: record) else {
                throw MacClippySnippetCreationError.unsupportedContent
            }

            let name = snippetName(for: body)
            let snippet = try snippetStore.create(name: name, body: body)
            snippetLookupSnapshot.replace(with: try snippetStore.list())
            return MacClippySnippetEntry(snippet: snippet)
        }
    }

    func createSnippet(name: String, trigger: String?, body: String) throws -> MacClippySnippetEntry {
        try withStoreLock {
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedName.isEmpty else {
                throw MacClippySnippetCreationError.invalidName
            }

            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MacClippySnippetCreationError.emptyBody
            }

            let normalizedTrigger = normalizedSnippetTrigger(trigger)
            if let normalizedTrigger, try snippetStore.find(trigger: normalizedTrigger) != nil {
                throw MacClippySnippetCreationError.duplicateTrigger
            }

            let snippet = try snippetStore.create(
                name: normalizedName,
                body: body,
                trigger: normalizedTrigger
            )
            let snippets = try snippetStore.list()
            snippetLookupSnapshot.replace(with: snippets)
            return MacClippySnippetEntry(snippet: snippet)
        }
    }

    private func snippetName(for body: String) -> String {
        let firstLine = body.components(separatedBy: .newlines).first ?? body
        let normalized = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Snippet" }
        return String(normalized.prefix(48))
    }

    private func normalizedSnippetTrigger(_ trigger: String?) -> String? {
        guard let trigger = trigger?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trigger.isEmpty else { return nil }
        return trigger.hasPrefix(";") ? trigger : ";\(trigger)"
    }

    func preview(id: RecordID) throws -> MacClippyRuntimePreviewPayload {
        try withStoreLock {
            switch try clipboardStore.body(for: id) {
            case let .text(value):
                return .text(value)
            case let .html(value):
                let record = ClipboardRecord.html(value)
                return .text(MacClippyClipboardText.plainText(from: record) ?? value)
            case let .rtf(data):
                let record = ClipboardRecord.rtf(data)
                guard let text = MacClippyClipboardText.plainText(from: record) else {
                    throw MacClippyStoreError.invalidStoredRecord
                }
                return .text(text)
            case let .image(blobID, _, _), let .encryptedImage(blobID, _, _):
                return .image(try blobStore.read(id: blobID))
            case let .files(urls):
                return .files(urls)
            }
        }
    }

    func details(id: RecordID) throws -> MacClippyItemDetails {
        try withStoreLock {
            guard let meta = try clipboardStore.metas(for: [id]).first else {
                throw MacClippyStoreError.recordNotFound
            }
            let record = try clipboardStore.body(for: id)
            let representations = try clipboardStore.representations(for: id).map { representation in
                let byteCount: Int
                let isAvailable: Bool
                switch representation.payloadState {
                case .present:
                    byteCount = representation.payloadBytes?.count ?? 0
                    isAvailable = representation.payloadBytes != nil
                case .spilled:
                    byteCount = representation.blobID.map(blobStore.byteSize) ?? 0
                    isAvailable = representation.blobID.map(blobStore.contains) ?? false
                case .unavailable:
                    byteCount = 0
                    isAvailable = false
                case .oversized:
                    byteCount = 0
                    isAvailable = false
                }
                return MacClippyItemRepresentationDetails(
                    uti: representation.uti,
                    payloadState: representation.payloadState,
                    byteCount: byteCount,
                    isAvailable: isAvailable
                )
            }
            let boardNames = try pinboardStore.list().compactMap { board in
                board.itemIDs.contains(id) ? board.name : nil
            }
            let textContent: String?
            let fileURLs: [URL]
            let imageDimensions: CGSize?
            switch record {
            case let .text(value):
                textContent = value
                fileURLs = []
                imageDimensions = nil
            case let .html(value):
                textContent = value
                fileURLs = []
                imageDimensions = nil
            case let .rtf(data):
                textContent = String(data: data, encoding: .utf8)
                    ?? MacClippyClipboardText.plainText(from: .rtf(data))
                fileURLs = []
                imageDimensions = nil
            case let .files(urls):
                textContent = nil
                fileURLs = urls
                imageDimensions = nil
            case let .image(_, width, height), let .encryptedImage(_, width, height):
                textContent = nil
                fileURLs = []
                imageDimensions = CGSize(width: width, height: height)
            }
            return MacClippyItemDetails(
                id: id,
                title: meta.customLabel ?? meta.preview,
                contentKind: record.contentKind,
                sourceAppBundleID: meta.sourceAppBundleID,
                created: meta.created,
                modified: meta.modified,
                frequency: meta.frequency,
                lastAccessed: meta.lastAccessed,
                customLabel: meta.customLabel,
                ocrText: meta.ocrText,
                preview: meta.preview,
                textContent: textContent,
                fileURLs: fileURLs,
                imageDimensions: imageDimensions,
                pinboardNames: boardNames,
                representations: representations
            )
        }
    }

    @discardableResult
    func edit(id: RecordID, text: String) throws -> ClipboardItemMeta {
        try withStoreLock {
            guard let oldMeta = try clipboardStore.metas(for: [id]).first else {
                throw MacClippyStoreError.recordNotFound
            }
            let oldRecord = try clipboardStore.body(for: id)
            let editedRecord: ClipboardRecord
            switch oldRecord {
            case .text:
                editedRecord = .text(text)
            case .html:
                editedRecord = .html(text)
            case .rtf:
                if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{\\rtf") {
                    editedRecord = .rtf(Data(text.utf8))
                } else {
                    let range = NSRange(location: 0, length: text.utf16.count)
                    let data = try NSAttributedString(string: text).data(
                        from: range,
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                    )
                    editedRecord = .rtf(data)
                }
            case .image, .encryptedImage, .files:
                throw MacClippyStoreError.invalidStoredRecord
            }
            let oldBlobIDs = try clipboardStore.blobIDs(for: id)
            let updated = try clipboardStore.update(id: id, with: editedRecord)
            do {
                let indexText = Self.searchableIndexText(for: editedRecord, ocrText: updated.ocrText, label: updated.customLabel)
                if indexText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try searchStore.remove(kind: .clipboardItem, id: id)
                } else {
                    try searchStore.upsert(kind: .clipboardItem, id: id, text: indexText)
                }

                // An edited text/HTML/RTF record may replace an oversized
                // representation Blob with an inline payload. Reclaim only
                // the blobs that disappeared from this record and are no
                // longer referenced elsewhere; FTS failure above restores the
                // old envelope before this cleanup can run.
                let newBlobIDs = try clipboardStore.blobIDs(for: id)
                let obsoleteBlobIDs = oldBlobIDs.subtracting(newBlobIDs)
                if !obsoleteBlobIDs.isEmpty {
                    let referenced = try clipboardStore.referencedBlobIDs()
                    for blobID in obsoleteBlobIDs where !referenced.contains(blobID) {
                        do {
                            try blobStore.delete(id: blobID)
                        } catch {
                            storageDegradedReasons.insert("orphan-blob-cleanup-failed")
                            MacClippyLog.record(
                                category: .blob,
                                code: .blobCleanupFailed,
                                operation: "edit_obsolete_blob_cleanup",
                                recoveryAction: "run_storage_reconciliation",
                                impact: "edited_record_saved_but_blob_cleanup_incomplete"
                            )
                        }
                    }
                }
            } catch {
                // The clipboard row is restored if its secondary FTS update
                // fails, so an edit is all-or-nothing from the user's view.
                do {
                    try clipboardStore.update(id: id, with: oldRecord, now: oldMeta.modified)
                } catch {
                    storageDegradedReasons.insert("edit-rollback-failed")
                    MacClippyLog.record(
                        category: .storage,
                        code: .recoveryFailed,
                        operation: "edit_record_rollback",
                        recoveryAction: "restore_backup_or_repair_storage",
                        impact: "edited_record_rollback_incomplete"
                    )
                }
                markSearchRepairNeeded()
                MacClippyLog.record(
                    category: .fts,
                    code: .ftsIndexFailed,
                    operation: "edit_fts_update",
                    recoveryAction: "repair_search_index",
                    impact: "edited_record_search_state_needs_repair"
                )
                throw error
            }
            return updated
        }
    }

    func preview(snippetID: RecordID) throws -> MacClippyRuntimePreviewPayload {
        try withStoreLock { .text(try snippetStore.fetch(id: snippetID).body) }
    }

    func pinboards() throws -> [MacClippyPinboardEntry] {
        try withStoreLock {
            try pinboardStore.list().map { board in
                MacClippyPinboardEntry(board: board, items: try pinboardItems(for: board))
            }
        }
    }

    func createPinboard(name: String, color: String?) throws -> Pinboard {
        try withStoreLock {
            try pinboardStore.create(name: name, color: color)
        }
    }

    func renamePinboard(id: RecordID, to name: String) throws {
        try withStoreLock {
            try pinboardStore.rename(id: id, to: name)
        }
    }

    func setPinboardColor(id: RecordID, color: String) throws {
        try withStoreLock {
            _ = try pinboardStore.mutate(id: id) { $0.color = color }
        }
    }

    func deletePinboard(id: RecordID) throws {
        try withStoreLock {
            try pinboardStore.delete(id: id)
        }
    }

    func pin(recordID: RecordID, to pinboardID: RecordID) throws {
        try withStoreLock {
            let board = try pinboardStore.fetch(id: pinboardID)
            guard try !clipboardStore.metas(for: [recordID]).isEmpty else {
                throw MacClippyStoreError.recordNotFound
            }
            guard !board.itemIDs.contains(recordID) else { return }
            try pinboardStore.addItem(recordID, to: pinboardID)
        }
    }

    // P2a: set or clear a trimmed custom label for a clipboard record and keep
    // the search index consistent with the record's preview plus OCR/label
    // metadata WITHOUT losing the existing searchable body text. A blank/
    // whitespace-only label clears the stored label (nil). The store trims,
    // bumps modified, and returns the updated meta; this method then rebuilds
    // the index text as body searchable text + OCR text + label and upserts it
    // so the label becomes searchable, OCR text remains searchable for images,
    // and the full body text remains searchable for text/html/rtf records.
    // Returns the updated meta so the dock can refresh the card without an
    // extra reload. Throws recordNotFound when the id is not present. Kept
    // internal so the shipped API surface does not grow; the dock model is the
    // sole caller and is in the same module.
    @discardableResult
    func setCustomLabel(id: RecordID, label: String?) throws -> ClipboardItemMeta {
        try withStoreLock {
            let meta = try clipboardStore.setCustomLabel(id: id, label: label)
            let body = try clipboardStore.body(for: id)
            let indexText = Self.searchableIndexText(for: body, ocrText: meta.ocrText, label: meta.customLabel)
            if indexText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // A record with no derivable text (e.g. an image with no OCR
                // and a cleared label) must not keep a stale index row that no
                // longer matches the record's visible text. An index error is
                // NOT swallowed as success: a failing remove propagates so the
                // dock reports an error instead of a false labelSaved.
                try searchStore.remove(kind: .clipboardItem, id: id)
            } else {
                // Rebuild the index as body searchable text + OCR text +
                // label. A failing upsert propagates so the dock reports an
                // error instead of a false labelSaved; the store label was
                // already persisted but the search index is now inconsistent,
                // which the user-visible error signals. Startup
                // reconciliation will later trim any orphan FTS row.
                do {
                    try searchStore.upsert(kind: .clipboardItem, id: id, text: indexText)
                } catch {
                    markSearchRepairNeeded()
                    MacClippyLog.record(
                        category: .fts,
                        code: .ftsIndexFailed,
                        operation: "label_fts_update",
                        recoveryAction: "repair_search_index",
                        impact: "label_saved_but_search_state_needs_repair"
                    )
                    throw error
                }
            }
            return meta
        }
    }

    // P2a: builds the search index text for a clipboard record from its body
    // searchable text, its OCR text, and its custom label. Each non-empty
    // component is joined with a newline so FTS5 tokenization treats them as
    // separate searchable segments; no existing body text is dropped. Returns
    // an empty string only when all three components are empty/nil so the
    // caller can decide to remove the index row instead of inserting a blank
    // one.
    private static func searchableIndexText(
        for record: ClipboardRecord,
        ocrText: String?,
        label: String?
    ) -> String {
        var segments: [String] = []
        if let bodyText = MacClippyClipboardText.plainText(from: record),
           !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(bodyText)
        }
        if let ocrText = ocrText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ocrText.isEmpty {
            segments.append(ocrText)
        }
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            segments.append(label)
        }
        return segments.joined(separator: "\n")
    }

    @discardableResult
    func paste(id: RecordID) throws -> PasteInjectionResult {
        try measureDiagnosticMetric("paste") {
            let content = try withStoreLock {
                let body = try clipboardStore.body(for: id)
                return try pasteboardContent(for: body, plain: false)
            }
            let result = pasteInjector.inject(content: content)
            if result == .injected {
                recordSuccessfulPasteFrequency(for: id)
            }
            return result
        }
    }

    @discardableResult
    func paste(snippetID: RecordID) throws -> PasteInjectionResult {
        try measureDiagnosticMetric("paste_snippet") {
            let body = try withStoreLock { try snippetStore.fetch(id: snippetID).body }
            return pasteInjector.inject(text: body)
        }
    }

    @discardableResult
    func copy(id: RecordID) throws -> Bool {
        try copy(id: id, plain: false)
    }

    @discardableResult
    func copy(id: RecordID, plain: Bool) throws -> Bool {
        let content = try withStoreLock {
            let body = try clipboardStore.body(for: id)
            return try pasteboardContent(for: body, plain: plain)
        }
        return pasteInjector.prepare(content)
    }

    @discardableResult
    func copy(snippetID: RecordID) throws -> Bool {
        let body = try withStoreLock { try snippetStore.fetch(id: snippetID).body }
        return pasteInjector.prepareText(body)
    }

    // Transformed copy/paste: read the record body under the existing store
    // lock, derive plain text via the existing MacClippyClipboardText path
    // (html/rtf are converted to plain text because the transform engine
    // operates on text), apply the given MacClippyTextTransform, then prepare
    // or inject the result as plain text (.text). Image and files records are
    // rejected explicitly with invalidStoredRecord so they are never silently
    // transformed or dropped; a malformed/undecodable rtf payload (no plain
    // text) is rejected the same way. Transformed copy only prepares the
    // pasteboard and never posts Cmd+V, matching copy(id:plain:). Transformed
    // paste injects Cmd+V and bumps frequency only when injection succeeds,
    // matching paste(id:). Neither path mutates the stored record or the
    // search index; the transform is a one-shot pasteboard operation.
    @discardableResult
    func copy(id: RecordID, transform: TextTransform) throws -> Bool {
        let text = try withStoreLock { try transformedPlainText(for: id, transform: transform) }
        return pasteInjector.prepare(.text(text))
    }

    @discardableResult
    func paste(id: RecordID, transform: TextTransform) throws -> PasteInjectionResult {
        try measureDiagnosticMetric("paste_transform") {
            let text = try withStoreLock { try transformedPlainText(for: id, transform: transform) }
            let result = pasteInjector.inject(content: .text(text))
            if result == .injected {
                recordSuccessfulPasteFrequency(for: id)
            }
            return result
        }
    }

    // Shared plain-text derivation + transform for copy/paste. Reads the body
    // under the caller's store lock, rejects non-text kinds and undecodable
    // rtf/html explicitly, and applies the transform. A nil plain-text
    // derivation for an otherwise text-bearing record is treated as an error
    // so an empty or raw-markup transform result is never silently produced
    // from a missing payload.
    private func transformedPlainText(for id: RecordID, transform: TextTransform) throws -> String {
        let body = try clipboardStore.body(for: id)
        switch body {
        case let .text(value):
            return transform.apply(to: value)
        case .html:
            guard let plain = MacClippyClipboardText.plainText(from: body) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return transform.apply(to: plain)
        case let .rtf(data):
            let rtfRecord = ClipboardRecord.rtf(data)
            guard let plain = MacClippyClipboardText.plainText(from: rtfRecord) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return transform.apply(to: plain)
        case .image, .encryptedImage, .files:
            // Images and files are not text and must not be silently
            // transformed or dropped; report an explicit error so the dock can
            // surface it instead of showing a misleading success.
            throw MacClippyStoreError.invalidStoredRecord
        }
    }

    @discardableResult
    func togglePin(id: RecordID, preferredPinboardID: RecordID? = nil) throws -> Bool {
        try withStoreLock {
            let boards = try pinboardStore.list()
            if let preferredPinboardID,
               let preferred = boards.first(where: { $0.id == preferredPinboardID }) {
                if preferred.itemIDs.contains(id) {
                    try pinboardStore.removeItem(id, from: preferred.id)
                } else {
                    try pinboardStore.addItem(id, to: preferred.id)
                }
                return true
            }

            if let containing = boards.first(where: { $0.itemIDs.contains(id) }) {
                try pinboardStore.removeItem(id, from: containing.id)
                return true
            }
            guard let defaultBoard = boards.first else { return false }
            try pinboardStore.addItem(id, to: defaultBoard.id)
            return true
        }
    }

    func delete(id: RecordID) throws {
        try withStoreLock {
            guard let journal = try clipboardStore.beginDeletion(ids: [id]) else {
                throw MacClippyStoreError.recordNotFound
            }
            try searchStore.remove(kind: .clipboardItem, id: id)
            try clipboardStore.delete(id: id)

            for board in try pinboardStore.list() where board.itemIDs.contains(id) {
                try pinboardStore.removeItem(id, from: board.id)
            }

            // Reclaim both primary image blobs and oversized representation
            // blobs as soon as the parent record is gone. Shared blobs remain
            // protected by the reference check.
            let referenced = try clipboardStore.referencedBlobIDs()
            for blobID in journal.blobIDs where !referenced.contains(blobID) {
                try blobStore.delete(id: blobID)
            }
            try clipboardStore.completeDeletion(operationID: journal.operationID)
        }
    }

    func delete(snippetID: RecordID) throws {
        try withStoreLock {
            try snippetStore.delete(id: snippetID)
            snippetLookupSnapshot.replace(with: try snippetStore.list())
        }
    }

    // Test-only direct append. The production capture path runs through the
    // observer and the capture mapper; tests of the batch store operations
    // (delete/pin/multi-paste) need records in the store without driving the
    // real pasteboard, so this internal helper writes a record directly. It is
    // intentionally internal (not public) so it is visible to the app test
    // target via @testable import but never part of the shipped API.
    //
    // Wrapped in #if DEBUG so Release builds contain no test helper and no
    // hard-coded fixture PNG. App tests run in the Debug configuration, so
    // @testable import continues to see this member during test builds.
    #if DEBUG
        @discardableResult
        internal func appendTestRecord(_ record: ClipboardRecord) throws -> ClipboardItemMeta {
            try withStoreLock {
                switch record {
                case let .text(value):
                    return try clipboardStore.append(.text(value))
                case let .html(value):
                    return try clipboardStore.append(.html(value))
                case let .rtf(data):
                    return try clipboardStore.append(.rtf(data))
                case let .image(_, width, height):
                    // Write a 1x1 PNG blob so the image record has a real blob id
                    // that BlobStore.read can resolve during multi-paste classify.
                    let png = Data([
                        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
                        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
                        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
                        0x42, 0x60, 0x82
                    ])
                    let blobID = try blobStore.write(png)
                    return try clipboardStore.append(.image(blobID: blobID, width: width, height: height))
                case let .encryptedImage(_, width, height):
                    let png = Data([
                        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
                        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
                        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
                        0x42, 0x60, 0x82
                    ])
                    let blobID = try blobStore.write(png)
                    return try clipboardStore.append(.image(blobID: blobID, width: width, height: height))
                case let .files(urls):
                    return try clipboardStore.append(.files(urls))
                }
            }
        }

        // P2b test-only append overload that accepts a sourceAppBundleID and an
        // explicit `now` so structured-search integration tests can exercise the
        // app: and before:/after: clauses without driving the real pasteboard.
        // Reuses clipboardStore.append's existing parameters; no production
        // capture behavior is duplicated. Same DEBUG/internal visibility as
        // appendTestRecord above so Release builds compile it out.
        @discardableResult
        internal func appendTestRecord(
            _ record: ClipboardRecord,
            sourceAppBundleID: String?,
            now: Date = Date()
        ) throws -> ClipboardItemMeta {
            try withStoreLock {
                switch record {
                case let .text(value):
                    return try clipboardStore.append(.text(value), sourceAppBundleID: sourceAppBundleID, now: now)
                case let .html(value):
                    return try clipboardStore.append(.html(value), sourceAppBundleID: sourceAppBundleID, now: now)
                case let .rtf(data):
                    return try clipboardStore.append(.rtf(data), sourceAppBundleID: sourceAppBundleID, now: now)
                case let .image(_, width, height), let .encryptedImage(_, width, height):
                    // Write a 1x1 PNG blob so the image record has a real blob id
                    // that BlobStore.read can resolve during preview/multi-paste.
                    let png = Data([
                        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
                        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
                        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
                        0x42, 0x60, 0x82
                    ])
                    let blobID = try blobStore.write(png)
                    return try clipboardStore.append(.image(blobID: blobID, width: width, height: height), sourceAppBundleID: sourceAppBundleID, now: now)
                case let .files(urls):
                    return try clipboardStore.append(.files(urls), sourceAppBundleID: sourceAppBundleID, now: now)
                }
            }
        }
    #endif

    // P2a test-only OCR seeding. The production OCR path runs through
    // scheduleOCR -> MacClippyOCRService and writes OCR text via
    // clipboardStore.setOCRText; tests of setCustomLabel's index rebuild need
    // an image record with OCR text present without driving the real Vision
    // recognizer. This internal helper writes OCR text directly to the store
    // under the existing storeLock, reusing the private clipboardStore.setOCRText
    // so no production OCR behavior is duplicated or changed. Intentionally
    // internal (not public) and #if DEBUG so Release builds contain no test
    // helper; @testable import sees it during Debug app test builds, matching
    // appendTestRecord above.
    #if DEBUG
        internal func setOCRTextForTest(id: RecordID, text: String) throws {
            try withStoreLock {
                try clipboardStore.setOCRText(id: id, text: text)
            }
        }
    #endif

    #if DEBUG
        // Test-only fault marker used to verify that an ordinary successful FTS
        // write cannot clear a degraded state. Only an explicit full repair may
        // clear `fts-repair-needed`.
        internal func markSearchIndexNeedsRepairForTest() throws {
            try withStoreLock {
                storageDegradedReasons.insert("fts-repair-needed")
                try searchStore.markRepairNeeded()
            }
        }

        // Test-only crash simulation for the deletion recovery path. The parent
        // record is removed after the durable journal is written, while FTS,
        // pinboards, and BlobStore are intentionally left untouched so the test
        // can exercise the same idempotent replay used at startup.
        internal func simulateInterruptedDeletionForTest(id: RecordID) throws {
            try withStoreLock {
                guard let journal = try clipboardStore.beginDeletion(ids: [id]) else {
                    throw MacClippyStoreError.recordNotFound
                }
                try clipboardStore.delete(id: id)
                _ = journal
            }
        }

        internal func replayPendingDeletionsForTest() throws {
            try withStoreLock {
                try replayPendingDeletionsLocked()
            }
        }

        internal func pendingDeletionCountForTest() throws -> Int {
            try withStoreLock {
                try clipboardStore.pendingDeletions().count
            }
        }

        internal func indexedClipboardIDsForTest() throws -> [RecordID] {
            try withStoreLock {
                try searchStore.indexedRecordIDs(kind: .clipboardItem)
            }
        }
    #endif

    // P1 batch delete: delete every supplied clipboard record, remove it from
    // every pinboard, and reclaim any image blob that is no longer referenced
    // by another record. The result lists the IDs that were actually deleted
    // (and were present), the IDs that were not found, and the IDs that were
    // present but whose per-item delete raised an error (failedIDs). A not-
    // found ID or a per-item error does NOT abort the batch; the remaining IDs
    // are still attempted so a single failing item cannot silently make the UI
    // report a complete success. No-filter semantics are preserved: the
    // operation acts only on the supplied IDs and never inspects or filters
    // their content. Only a hard preflight failure (e.g. the DB read to
    // classify present/missing) throws and aborts the whole batch, since in
    // that case no per-item outcome is known.
    @discardableResult
    func delete(ids: [RecordID]) throws -> MacClippyBatchDeleteResult {
        try withStoreLock {
            try deleteLocked(ids: ids)
        }
    }

    @discardableResult
    func deleteUnpinnedHistory() throws -> MacClippyBatchDeleteResult {
        try withStoreLock {
            let protectedIDs = try PinboardStore.protectedIDs(from: pinboardStore)
            let candidateIDs = try clipboardStore.allMetas()
                .map(\.id)
                .filter { !protectedIDs.contains($0) }
            return try deleteLocked(ids: candidateIDs)
        }
    }

    private func deleteLocked(ids: [RecordID]) throws -> MacClippyBatchDeleteResult {
        var deletedIDs: [RecordID] = []
        var missingIDs: [RecordID] = []
        var failedIDs: [RecordID] = []
        var candidateIDs: [RecordID] = []
        var pendingCleanup: [(id: RecordID, journal: MacClippyDeletionJournalEntry)] = []
        var seenIDs = Set<RecordID>()

        let presentMetas = try clipboardStore.metas(for: ids)
        let presentIDs = Set(presentMetas.map(\.id))
        for id in ids {
            if presentIDs.contains(id), seenIDs.insert(id).inserted {
                candidateIDs.append(id)
            } else {
                missingIDs.append(id)
            }
        }

        let boards = try pinboardStore.list()
        for id in candidateIDs {
            // Delete the database rows first, but defer Blob reference
            // inspection until every candidate has been processed. This
            // keeps a large batch at one O(history) reference scan instead of
            // repeating that scan once per record.
            do {
                guard let journal = try clipboardStore.beginDeletion(ids: [id]) else {
                    failedIDs.append(id)
                    continue
                }
                try searchStore.remove(kind: .clipboardItem, id: id)
                try clipboardStore.delete(id: id)
                for board in boards where board.itemIDs.contains(id) {
                    try pinboardStore.removeItem(id, from: board.id)
                }
                pendingCleanup.append((id: id, journal: journal))
            } catch {
                // Record the failure and continue with the remaining IDs.
                // The failing ID is NOT counted as deleted; any durable
                // journal remains available for startup replay.
                failedIDs.append(id)
            }
        }

        guard !pendingCleanup.isEmpty else {
            return MacClippyBatchDeleteResult(
                deletedIDs: deletedIDs,
                missingIDs: missingIDs,
                failedIDs: failedIDs
            )
        }

        let referenced: Set<String>
        do {
            referenced = try clipboardStore.referencedBlobIDs()
        } catch {
            // Parent rows may already be gone, but their deletion journals
            // make this state recoverable. Leave those journals pending and
            // report the affected IDs instead of claiming complete cleanup.
            failedIDs.append(contentsOf: pendingCleanup.map(\.id))
            return MacClippyBatchDeleteResult(
                deletedIDs: deletedIDs,
                missingIDs: missingIDs,
                failedIDs: failedIDs
            )
        }

        for pending in pendingCleanup {
            do {
                for blobID in pending.journal.blobIDs where !referenced.contains(blobID) {
                    try blobStore.delete(id: blobID)
                }
                try clipboardStore.completeDeletion(operationID: pending.journal.operationID)
                deletedIDs.append(pending.id)
            } catch {
                // Keep the operation journal for replay if Blob cleanup or
                // journal completion fails; do not mask it as a success.
                failedIDs.append(pending.id)
            }
        }

        return MacClippyBatchDeleteResult(
            deletedIDs: deletedIDs,
            missingIDs: missingIDs,
            failedIDs: failedIDs
        )
    }

    // P1 batch pin: add every supplied clipboard record to the target
    // pinboard, skipping records that are already members and validating both
    // the board and each record under the existing store lock. The result
    // lists the IDs that were newly pinned, the IDs that were already members
    // (safe no-ops), the IDs that were not found, and the IDs that were
    // present but whose per-item pin raised an error (failedIDs). A not-found
    // ID or a per-item error does NOT abort the batch; the remaining IDs are
    // still attempted so a single failing item cannot silently make the UI
    // report a complete success. No-filter semantics are preserved: the
    // operation acts only on the supplied IDs and never inspects or filters
    // their content. Only a hard preflight failure (board fetch or the DB read
    // to classify present/missing) throws and aborts the whole batch.
    @discardableResult
    func pin(recordIDs: [RecordID], to pinboardID: RecordID) throws -> MacClippyBatchPinResult {
        try withStoreLock {
            let board = try pinboardStore.fetch(id: pinboardID)
            let presentMetas = try clipboardStore.metas(for: recordIDs)
            let presentIDs = Set(presentMetas.map(\.id))

            var pinnedIDs: [RecordID] = []
            var duplicateIDs: [RecordID] = []
            var missingIDs: [RecordID] = []
            var failedIDs: [RecordID] = []

            for id in recordIDs {
                if !presentIDs.contains(id) {
                    missingIDs.append(id)
                } else if board.itemIDs.contains(id) {
                    duplicateIDs.append(id)
                } else {
                    // Per-item pin: collect a failure instead of aborting the
                    // whole batch so the UI can report exactly which items
                    // failed and never report a complete success for a partial
                    // batch.
                    do {
                        try pinboardStore.addItem(id, to: pinboardID)
                        pinnedIDs.append(id)
                    } catch {
                        failedIDs.append(id)
                    }
                }
            }

            return MacClippyBatchPinResult(
                boardName: board.name,
                pinnedIDs: pinnedIDs,
                duplicateIDs: duplicateIDs,
                missingIDs: missingIDs,
                failedIDs: failedIDs
            )
        }
    }

    // P1 ordered multi-paste: resolve the selection through the pure
    // MacClippyDockMultiPastePolicy. For a homogeneous text-compatible
    // selection, merge the plain-text payloads in visual order with a newline
    // delimiter and inject a single paste (preserving the target app). For a
    // mixed selection, never paste a subset: return an explicit
    // manualPasteRequired result carrying the supported and unsupported IDs so
    // the caller can report exactly what was not pasted. No item is silently
    // dropped. The frequency of every pasted (text-merged) record is bumped.
    @discardableResult
    func pasteOrdered(ids: [RecordID]) throws -> MacClippyMultiPasteResult {
        try measureDiagnosticMetric("paste_ordered") {
            let resolution = try resolveOrderedMultiSelection(ids: ids)

            switch resolution {
            case let .mergedText(text):
                let injection = pasteInjector.inject(content: .text(text))
                if injection == .injected {
                    for id in ids {
                        recordSuccessfulPasteFrequency(for: id)
                    }
                }
                return .merged(injected: injection == .injected)
            case let .mixed(supportedIDs, unsupportedIDs, unsupportedKinds):
                return .mixed(
                    supportedIDs: supportedIDs,
                    unsupportedIDs: unsupportedIDs,
                    unsupportedKinds: unsupportedKinds
                )
            case let .textUnavailable(availableIDs, unavailableIDs, unavailableKinds):
                // No paste and no frequency bump: an unavailable/undecodable
                // payload must not be silently merged as an empty piece, and the
                // available records must not be pasted as a partial selection.
                return .textUnavailable(
                    availableIDs: availableIDs,
                    unavailableIDs: unavailableIDs,
                    unavailableKinds: unavailableKinds
                )
            }
        }
    }

    // P1 ordered multi-copy: resolve the selection through the SAME pure
    // MacClippyDockMultiPastePolicy as pasteOrdered (shared resolution, no
    // classification duplication), then for a homogeneous text-compatible
    // selection prepare the merged text on the pasteboard WITHOUT injecting
    // any keyboard event. Copy all must never post a paste keystroke. The
    // mixed/unavailable cases mirror pasteOrdered so the dock shows the same
    // no-silent-data-loss feedback and never prepares a subset. Copy never
    // bumps frequency (matching the single copy(id:) path); only paste bumps
    // frequency.
    @discardableResult
    func copyOrdered(ids: [RecordID]) throws -> MacClippyMultiCopyResult {
        let resolution = try resolveOrderedMultiSelection(ids: ids)

        switch resolution {
        case let .mergedText(text):
            // Prepare the pasteboard only; never inject a Cmd+V keystroke.
            // The pasteInjector's prepare path uses the writeSentinel so Mac
            // Clippy's own write is suppressed by the observer, exactly like
            // the single copy(id:) path.
            let prepared = pasteInjector.prepare(.text(text))
            return .merged(prepared: prepared)
        case let .mixed(supportedIDs, unsupportedIDs, unsupportedKinds):
            return .mixed(
                supportedIDs: supportedIDs,
                unsupportedIDs: unsupportedIDs,
                unsupportedKinds: unsupportedKinds
            )
        case let .textUnavailable(availableIDs, unavailableIDs, unavailableKinds):
            // No pasteboard write: an unavailable/undecodable payload must not
            // be silently merged as an empty piece, and the available records
            // must not be copied as a partial selection.
            return .textUnavailable(
                availableIDs: availableIDs,
                unavailableIDs: unavailableIDs,
                unavailableKinds: unavailableKinds
            )
        }
    }

    // Mixed-content sequential queue paste. Processes the ordered selected IDs
    // one at a time in visual order, injecting a separate Cmd+V per record so
    // mixed selections (text + image + files) can each be consumed by the
    // target app. This is NOT the homogeneous-only pasteOrdered path: every
    // stored content kind the single paste(id:) path supports (text, html, rtf,
    // image, files) is pasted in turn using the same pasteboardContent(for:)
    // seam.
    //
    // Per record:
    //   - Read the body under the store lock and prepare its
    //     MacClippyPasteboardContent. A missing record, a malformed/undecodable
    //     payload (e.g. malformed RTF), or any body-read failure is reported
    //     explicitly with its ID and known content kind (or .unsupported when
    //     the body cannot be read at all) in the unavailable lists, and the
    //     queue CONTINUES with the remaining IDs — nothing is silently skipped.
    //   - Inject one Cmd+V through the shared MacClippyPasteInjector. Bump that
    //     record's frequency only after .injected.
    //   - If the injector returns .manualPasteRequired, STOP immediately: the
    //     current pasteboard item has not been consumed automatically. Return
    //     the current ID plus all remaining IDs in remainingIDs; do not claim
    //     them injected and do not continue posting events.
    //   - After a successful injection, wait MacClippyQueuePastePolicy.
    //    settleInterval off the main thread so the target app can consume the
    //     paste before the next record overwrites the pasteboard. The store
    //     lock is NOT held while sleeping.
    //
    // Ordering is deterministic: injectedIDs, unavailableIDs/unavailableKinds,
    // and remainingIDs all follow the supplied visual order. This is a one-shot
    // ordered execution; no queue database or speculative persistence is added.
    @discardableResult
    func pasteQueued(ids: [RecordID]) throws -> MacClippyQueuePasteResult {
        measureDiagnosticMetric("paste_queue") {
            var injectedIDs: [RecordID] = []
            var unavailableIDs: [RecordID] = []
            var unavailableKinds: [MacClippyDockMultiPastePolicy.Kind] = []

            for (index, id) in ids.enumerated() {
                // Prepare the pasteboard content for this record under the store
                // lock, using the same seam as paste(id:). A failure here is an
                // explicit unavailable result, not a silent skip; the queue
                // continues with the remaining IDs.
                enum Preparation {
                    case content(MacClippyPasteboardContent)
                    case unavailable(MacClippyDockMultiPastePolicy.Kind)
                }
                let preparation: Preparation = withStoreLock {
                    () -> Preparation in
                    do {
                        let body = try clipboardStore.body(for: id)
                        let content = try pasteboardContent(for: body, plain: false)
                        return .content(content)
                    } catch {
                        // body(for:) throws recordNotFound when the id is missing
                        // and invalidStoredRecord when the payload is malformed/
                        // undecodable (e.g. malformed RTF). Either way the record
                        // cannot produce pasteboard content; report it with the
                        // known kind when the body decoded far enough to reveal it,
                        // otherwise .unsupported. A missing record's body cannot be
                        // read at all, so it reports .unsupported.
                        if let kind = (try? clipboardStore.body(for: id)).map(\.contentKind) {
                            return .unavailable(MacClippyDockMultiPasteKindMapping.kind(for: kind))
                        }
                        return .unavailable(.unsupported)
                    }
                }

                switch preparation {
                case let .unavailable(kind):
                    unavailableIDs.append(id)
                    unavailableKinds.append(kind)
                    continue
                case let .content(content):
                    // Inject one Cmd+V. The injector writes the pasteboard and
                    // posts the keystroke; the store lock is NOT held across the
                    // inject call so a slow Accessibility post cannot block other
                    // store users.
                    let injection = pasteInjector.inject(content: content)
                    switch injection {
                    case .injected:
                        // Bump frequency only after a successful injection,
                        // matching paste(id:). Done under the store lock so the
                        // bump is atomic with respect to other store users.
                        recordSuccessfulPasteFrequency(for: id)
                        injectedIDs.append(id)
                    case .manualPasteRequired:
                        // The current pasteboard item has not been consumed
                        // automatically. STOP immediately: do not claim the
                        // current or any remaining ID injected, and do not post
                        // further events. remainingIDs is the current ID plus every
                        // not-yet-attempted ID in visual order.
                        let remainingIDs = Array(ids[index...])
                        return .manualPasteRequired(
                            injectedIDs: injectedIDs,
                            unavailableIDs: unavailableIDs,
                            unavailableKinds: unavailableKinds,
                            manualPasteRequiredID: id,
                            remainingIDs: remainingIDs
                        )
                    }
                }

                // Wait between successful injections so the target app can consume
                // each paste before the next record overwrites the pasteboard. The
                // sleep is off the main thread and the store lock is NOT held. Skip
                // the wait after the last record so the queue does not trail an
                // extra delay.
                if index < ids.count - 1 {
                    Thread.sleep(forTimeInterval: MacClippyQueuePastePolicy.settleInterval)
                }
            }

            return .completed(
                injectedIDs: injectedIDs,
                unavailableIDs: unavailableIDs,
                unavailableKinds: unavailableKinds
            )
        }
    }

    // Shared ordered-selection resolution for pasteOrdered and copyOrdered.
    // Runs the pure MacClippyDockMultiPastePolicy under the store lock so both
    // paths share one classification and never drift. Returns the policy
    // result (mergedText / mixed / textUnavailable) without performing any
    // pasteboard write or paste injection.
    private func resolveOrderedMultiSelection(ids: [RecordID]) throws -> MacClippyDockMultiPastePolicy.Result {
        withStoreLock {
            MacClippyDockMultiPastePolicy.resolve(
                orderedSelectedIDs: ids,
                kindForID: { [clipboardStore] id in
                    let contentKind = (try? clipboardStore.body(for: id))?.contentKind ?? .text
                    return MacClippyDockMultiPasteKindMapping.kind(for: contentKind)
                },
                textForID: { [clipboardStore, blobStore] id in
                    guard let record = try? clipboardStore.body(for: id) else { return nil }
                    switch record {
                    case let .text(value):
                        return value
                    case let .html(value):
                        return MacClippyClipboardText.plainText(from: record) ?? value
                    case let .rtf(data):
                        let rtfRecord = ClipboardRecord.rtf(data)
                        return MacClippyClipboardText.plainText(from: rtfRecord)
                    case let .image(blobID, _, _), let .encryptedImage(blobID, _, _):
                        // Images are not text-compatible; the policy already
                        // classified them as unsupported. Return nil so the
                        // merge never accidentally includes a blob id.
                        _ = blobID
                        _ = blobStore
                        return nil
                    case let .files(urls):
                        _ = urls
                        return nil
                    }
                }
            )
        }
    }

    deinit {
        stop()
        databases.forEach { try? $0.queue.close() }
    }

    private func capture(_ change: PasteboardChange) {
        measureDiagnosticMetric("capture") {
            // P0 no-filter capture: retain every external NSPasteboard representation
            // (UTI + raw Data), including concealed, transient, custom, and unknown
            // UTIs. The observer's write sentinel already suppressed Mac Clippy's
            // own writes, so anything that reaches here is external content and is
            // captured without applying the legacy regex/concealed/transient/app
            // exclusions. The primary payload drives the existing card/preview/
            // paste path; the representations array is persisted alongside it so
            // no external representation is lost.
            let payload = MacClippyCaptureMapper.payload(for: change)
            let representations = MacClippyCaptureMapper.representations(for: change)

            // Capture even when no known primary payload is derived, as long as
            // there is at least one external representation. This keeps custom and
            // unknown UTIs visible in history via their representations even when
            // the legacy mapper could not pick a primary slot.
            guard payload != nil || !representations.isEmpty else { return }

            do {
                try persist(payload, representations: representations, sourceAppBundleID: change.sourceAppBundleID)
            } catch {
                MacClippyLog.record(
                    category: .capture,
                    code: .capturePersistFailed,
                    operation: "capture_persist",
                    recoveryAction: "retry_next_clipboard_change",
                    impact: "clipboard_change_not_saved"
                )
            }
        }
    }

    private func persist(
        _ payload: MacClippyCapturePayload?,
        representations: [MacClippyClipboardRepresentation],
        sourceAppBundleID: String?
    ) throws {
        let result = try withStoreLock { () throws -> (ClipboardItemMeta, Data?) in
            var generatedBlobID: String?
            let record: ClipboardRecord

            switch payload {
            case let .text(value):
                record = .text(value)
            case let .rtf(data):
                record = .rtf(data)
            case let .html(value):
                record = .html(value)
            case let .image(data, width, height):
                let blobID = try blobStore.write(data)
                generatedBlobID = blobID
                record = .image(blobID: blobID, width: width, height: height)
            case let .files(urls):
                record = .files(urls)
            case .none:
                // No known primary slot: synthesize a text preview from the
                // first text-bearing representation so the record is visible
                // in history with a meaningful card. The full representation
                // set is still persisted below.
                let fallbackText = MacClippyCaptureMapper.plainText(for: representations) ?? "(no preview)"
                record = .text(fallbackText)
            }

            let meta: ClipboardItemMeta
            do {
                meta = try clipboardStore.append(
                    record,
                    representations: representations,
                    sourceAppBundleID: sourceAppBundleID,
                    spillPayload: { [blobStore] data in
                        // Spill oversized representation payloads to BlobStore
                        // so the side table stays small; the bytes are
                        // encrypted by BlobStore before they hit disk.
                        try blobStore.write(data)
                    },
                    deleteSpilledPayload: { [weak self, blobStore] blobID in
                        // Compensating rollback for spilled blobs when the
                        // atomic append transaction fails. If the cleanup
                        // itself fails, retain a degraded reason and let
                        // startup reconciliation retry it instead of hiding
                        // an orphan behind a successful-looking capture
                        // failure.
                        do {
                            try blobStore.delete(id: blobID)
                        } catch {
                            self?.storageDegradedReasons.insert("orphan-blob-cleanup-failed")
                            MacClippyLog.record(
                                category: .blob,
                                code: .blobCleanupFailed,
                                operation: "capture_spill_rollback_cleanup",
                                recoveryAction: "run_storage_reconciliation",
                                impact: "capture_failed_with_possible_orphan_blob"
                            )
                        }
                    }
                )
            } catch {
                if let generatedBlobID {
                    do {
                        try blobStore.delete(id: generatedBlobID)
                    } catch {
                        MacClippyLog.record(
                            category: .blob,
                            code: .blobCleanupFailed,
                            operation: "capture_rollback_blob_cleanup",
                            recoveryAction: "run_storage_reconciliation",
                            impact: "possible_orphan_blob"
                        )
                    }
                }
                throw error
            }

            if let searchableText = searchableText(
                for: payload,
                record: record,
                representations: representations
            ) {
                do {
                    try searchStore.upsert(id: meta.id, text: searchableText)
                } catch {
                    markSearchRepairNeeded()
                    MacClippyLog.record(
                        category: .fts,
                        code: .ftsIndexFailed,
                        operation: "capture_fts_upsert",
                        recoveryAction: "repair_search_index",
                        impact: "record_saved_but_not_searchable"
                    )
                }
            }

            return (meta, payload?.imageData)
        }

        if let imageData = result.1 {
            scheduleOCR(for: imageData, recordID: result.0.id)
        }

    }

    private func searchableText(
        for payload: MacClippyCapturePayload?,
        record: ClipboardRecord,
        representations: [MacClippyClipboardRepresentation]
    ) -> String? {
        var parts: [String] = []
        if let text = payload?.searchableText {
            parts.append(text)
        } else if let fallback = MacClippyCaptureMapper.plainText(for: representations) {
            parts.append(fallback)
        }

        if case let .files(urls) = record {
            parts.append(contentsOf: urls.flatMap { [$0.lastPathComponent, $0.path] })
        }

        // Keep unknown/custom representation types discoverable without
        // trying to decode arbitrary binary payloads.
        parts.append(contentsOf: representations.map(\.uti))
        let value = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return value.isEmpty ? nil : value
    }

    private func scheduleOCR(for data: Data, recordID: RecordID) {
        let clipboardStore = clipboardStore
        let searchStore = searchStore

        Task.detached(priority: .utility) {
            do {
                let text = try await MacClippyOCRService().recognize(data: data)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }

                try self.withStoreLock {
                    guard try !clipboardStore.metas(for: [recordID]).isEmpty else { return }
                    try clipboardStore.setOCRText(id: recordID, text: text)

                    // Recheck after the record update so deletion during OCR cannot
                    // leave an index row for a record that is already gone.
                    guard try !clipboardStore.metas(for: [recordID]).isEmpty else {
                        try searchStore.remove(id: recordID)
                        return
                    }
                    try searchStore.upsert(id: recordID, text: text)

                    if try clipboardStore.metas(for: [recordID]).isEmpty {
                        try searchStore.remove(id: recordID)
                    }
                }
            } catch {
                MacClippyLog.record(
                    category: .capture,
                    code: .ocrFailed,
                    operation: "ocr_update",
                    recoveryAction: "retry_ocr_from_record",
                    impact: "ocr_search_text_unavailable"
                )
            }
        }
    }

    private func enforceRetention() {
        let policy = MacClippyRetentionPreferences.policy()
        do {
            try withStoreLock {
                try policy.enforce(
                    store: clipboardStore,
                    blobs: blobStore,
                    search: searchStore,
                    pinboards: pinboardStore
                )
            }
        } catch {
            MacClippyLog.record(
                category: .storage,
                code: .retentionFailed,
                operation: "retention_maintenance",
                recoveryAction: "retry_storage_maintenance",
                impact: "history_cleanup_incomplete"
            )
        }
    }

    // Best-effort startup reconciliation: trim orphan blobs (no record
    // references them) and orphan FTS rows (no clipboard record for the
    // indexed id). Runs off-main once at start; failures are logged and never
    // block capture. See MacClippyReconciliation for the detection logic.
    private func reconcileStorage() {
        measureDiagnosticMetric("storage_reconciliation") {
            do {
                let result = try withStoreLock {
                    try replayPendingDeletionsLocked()
                    return try MacClippyReconciliation.reconcile(
                        store: clipboardStore,
                        search: searchStore,
                        blobs: blobStore,
                        deleteBlob: { [blobStore] id in
                            try blobStore.delete(id: id)
                        }
                    )
                }
                withStoreLock {
                    storageDegradedReasons.remove("storage-reconciliation-failed")
                    if result.missingBlobIDs.isEmpty {
                        storageDegradedReasons.remove("missing-blob-references")
                    } else {
                        storageDegradedReasons.insert("missing-blob-references")
                    }
                    if result.failedBlobCleanupIDs.isEmpty {
                        storageDegradedReasons.remove("orphan-blob-cleanup-failed")
                    } else {
                        storageDegradedReasons.insert("orphan-blob-cleanup-failed")
                    }
                    if result.failedFTSCleanupIDs.isEmpty {
                        storageDegradedReasons.remove("orphan-fts-cleanup-failed")
                    } else {
                        storageDegradedReasons.insert("orphan-fts-cleanup-failed")
                    }
                }
                if !result.isEmpty {
                    let hasOrphans = !result.orphanBlobIDs.isEmpty || !result.orphanFTSRecordIDs.isEmpty
                    if result.failedBlobCleanupIDs.isEmpty,
                       result.failedFTSCleanupIDs.isEmpty,
                       hasOrphans {
                        MacClippyLog.record(
                            category: .storage,
                            code: .reconciliationCompleted,
                            operation: "startup_reconciliation",
                            recoveryAction: "none",
                            impact: "orphan_cleanup_completed"
                        )
                    }
                    if !result.failedBlobCleanupIDs.isEmpty || !result.failedFTSCleanupIDs.isEmpty {
                        MacClippyLog.record(
                            category: .storage,
                            code: .reconciliationFailed,
                            operation: "startup_reconciliation_cleanup",
                            recoveryAction: "export_diagnostics_and_retry",
                            impact: "orphan_cleanup_incomplete"
                        )
                    }
                    if !result.missingBlobIDs.isEmpty {
                        MacClippyLog.record(
                            category: .blob,
                            code: .blobIntegrityFailed,
                            operation: "startup_blob_integrity_check",
                            recoveryAction: "restore_backup_or_delete_damaged_records",
                            impact: "missing_blob_references"
                        )
                    }
                }
            } catch {
                _ = withStoreLock {
                    storageDegradedReasons.insert("storage-reconciliation-failed")
                }
                MacClippyLog.record(
                    category: .storage,
                    code: .reconciliationFailed,
                    operation: "startup_reconciliation",
                    recoveryAction: "export_diagnostics_and_retry",
                    impact: "orphan_cleanup_incomplete"
                )
            }

            // Reconciliation can repair orphan rows, but it cannot prove that
            // every database is still usable. Run the bounded health check after
            // the recovery pass and record only fixed database names/status
            // categories. This keeps a degraded startup observable without
            // blocking the menu-bar lifecycle or exposing SQLite details.
            recordStartupHealthIfNeeded()
        }
    }

    private func recordStartupHealthIfNeeded() {
        let health = withStoreLock { storageHealthLocked() }
        for databaseName in ["clipboard", "search", "pinboards", "snippets"] {
            guard let report = health[databaseName], report.status != .healthy else { continue }
            let impact = report.status == .unrecoverable
                ? "storage_unrecoverable"
                : "storage_repairable"
            MacClippyLog.record(
                category: .storage,
                code: .databaseHealthFailed,
                operation: "startup_health_check_\(databaseName)",
                recoveryAction: report.status == .unrecoverable
                    ? "restore_backup_or_reinstall_storage"
                    : "open_storage_recovery",
                impact: impact
            )
        }
    }

    private func markSearchRepairNeeded() {
        storageDegradedReasons.insert("fts-repair-needed")
        do {
            try searchStore.markRepairNeeded()
        } catch {
            MacClippyLog.record(
                category: .storage,
                code: .databaseHealthFailed,
                operation: "persist_fts_repair_marker",
                recoveryAction: "export_diagnostics_and_repair_storage",
                impact: "fts_repair_state_not_persisted"
            )
        }
    }

    /// Replays deletion operations left in the clipboard database by a force
    /// quit or a secondary-store/blob failure. Every step is idempotent; the
    /// journal is removed only after all known side effects have completed.
    private func replayPendingDeletionsLocked() throws {
        for journal in try clipboardStore.pendingDeletions() {
            for id in journal.recordIDs {
                try searchStore.remove(kind: .clipboardItem, id: id)
                try clipboardStore.delete(id: id)
            }

            for board in try pinboardStore.list() {
                for id in journal.recordIDs where board.itemIDs.contains(id) {
                    try pinboardStore.removeItem(id, from: board.id)
                }
            }

            let referenced = try clipboardStore.referencedBlobIDs()
            for blobID in journal.blobIDs where !referenced.contains(blobID) {
                try blobStore.delete(id: blobID)
            }
            try clipboardStore.completeDeletion(operationID: journal.operationID)
        }
    }

    private func storageHealthLocked() -> [String: MacClippyDatabaseHealthReport] {
        var health = [
            "clipboard": clipboardStore.databaseHealth(),
            "search": searchStore.databaseHealth(),
            "pinboards": pinboardStore.databaseHealth(),
            "snippets": snippetStore.databaseHealth()
        ]
        if storageDegradedReasons.contains("missing-blob-references"),
           let clipboard = health["clipboard"] {
            let issues = Array(Set(clipboard.issues + ["missing-blob-references"])).sorted()
            let status: MacClippyDatabaseHealthStatus = clipboard.status == .unrecoverable
                ? .unrecoverable
                : .degraded
            health["clipboard"] = MacClippyDatabaseHealthReport(
                status: status,
                quickCheckPassed: clipboard.quickCheckPassed,
                foreignKeyViolationCount: clipboard.foreignKeyViolationCount,
                missingTables: clipboard.missingTables,
                issues: issues
            )
        }
        if storageDegradedReasons.contains("storage-reconciliation-failed")
            || storageDegradedReasons.contains("orphan-blob-cleanup-failed") {
            if let clipboard = health["clipboard"] {
                var reconciliationIssues: [String] = []
                if storageDegradedReasons.contains("storage-reconciliation-failed") {
                    reconciliationIssues.append("storage-reconciliation-failed")
                }
                if storageDegradedReasons.contains("orphan-blob-cleanup-failed") {
                    reconciliationIssues.append("orphan-blob-cleanup-failed")
                }
                let issues = Array(Set(clipboard.issues + reconciliationIssues)).sorted()
                health["clipboard"] = MacClippyDatabaseHealthReport(
                    status: clipboard.status == .unrecoverable ? .unrecoverable : .degraded,
                    quickCheckPassed: clipboard.quickCheckPassed,
                    foreignKeyViolationCount: clipboard.foreignKeyViolationCount,
                    missingTables: clipboard.missingTables,
                    issues: issues
                )
            }
        }
        if storageDegradedReasons.contains("orphan-fts-cleanup-failed"),
           let search = health["search"] {
            let issues = Array(Set(search.issues + ["orphan-fts-cleanup-failed"])).sorted()
            health["search"] = MacClippyDatabaseHealthReport(
                status: search.status == .unrecoverable ? .unrecoverable : .degraded,
                quickCheckPassed: search.quickCheckPassed,
                foreignKeyViolationCount: search.foreignKeyViolationCount,
                missingTables: search.missingTables,
                issues: issues
            )
        }
        let ftsRepairNeeded = storageDegradedReasons.contains("fts-repair-needed") || searchStore.repairNeeded()
        guard ftsRepairNeeded,
              let search = health["search"] else {
            return health
        }
        let issues = Array(Set(search.issues + ["fts-repair-needed"])).sorted()
        let status: MacClippyDatabaseHealthStatus = search.status == .unrecoverable
            ? .unrecoverable
            : .repairable
        health["search"] = MacClippyDatabaseHealthReport(
            status: status,
            quickCheckPassed: search.quickCheckPassed,
            foreignKeyViolationCount: search.foreignKeyViolationCount,
            missingTables: search.missingTables,
            issues: issues
        )
        return health
    }

    private func pinboardItems(for board: Pinboard) throws -> [MacClippyHistoryEntry] {
        let metas = try clipboardStore.metas(for: board.itemIDs)
        let metaByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
        var entriesByID: [RecordID: MacClippyHistoryEntry] = [:]
        var uncachedIDs: [RecordID] = []

        for itemID in board.itemIDs {
            guard let meta = metaByID[itemID] else { continue }
            let key = cacheKey(for: meta)
            if let cached = historyEntryCache.object(forKey: key) {
                entriesByID[itemID] = cached.entry
            } else {
                uncachedIDs.append(itemID)
            }
        }

        if !uncachedIDs.isEmpty {
            let bodies = try clipboardStore.bodies(for: uncachedIDs)
            for itemID in uncachedIDs {
                guard let meta = metaByID[itemID], let body = bodies[itemID] else { continue }
                let entry = entry(for: meta, body: body)
                historyEntryCache.setObject(
                    MacClippyHistoryEntryCacheBox(entry),
                    forKey: cacheKey(for: meta),
                    cost: entry.preview.utf8.count
                )
                entriesByID[itemID] = entry
            }
        }

        return board.itemIDs.compactMap { entriesByID[$0] }
    }

    private func entry(for meta: ClipboardItemMeta) -> MacClippyHistoryEntry? {
        let key = cacheKey(for: meta)
        if let cached = historyEntryCache.object(forKey: key) {
            return cached.entry
        }
        guard let body = try? clipboardStore.body(for: meta.id) else { return nil }
        let entry = entry(for: meta, body: body)
        historyEntryCache.setObject(
            MacClippyHistoryEntryCacheBox(entry),
            forKey: key,
            cost: entry.preview.utf8.count
        )
        return entry
    }

    private func cacheKey(for meta: ClipboardItemMeta) -> NSString {
        let label = meta.customLabel ?? ""
        let ocrText = meta.ocrText ?? ""
        let lastAccessed = meta.lastAccessed?.timeIntervalSince1970 ?? 0
        return "\(meta.id.rawValue)#\(meta.lamport)#\(meta.modified.timeIntervalSince1970)#\(meta.preview)#\(label)#\(ocrText)#\(meta.frequency)#\(lastAccessed)" as NSString
    }

    private func entry(for meta: ClipboardItemMeta, body: ClipboardRecord) -> MacClippyHistoryEntry {
        let preview: String
        switch body {
        case let .text(value):
            // The stored preview is intentionally short for indexing and
            // metadata. Cards receive the already-loaded full body so the
            // view can decide where visual truncation belongs.
            preview = value
        case let .html(value):
            preview = MacClippyClipboardText.plainText(from: body) ?? value
        case .rtf:
            preview = MacClippyClipboardText.plainText(from: body) ?? meta.preview
        case .image, .encryptedImage:
            if let ocrText = meta.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !ocrText.isEmpty {
                preview = ocrText
            } else {
                preview = meta.preview
            }
        case .files:
            preview = meta.preview
        }
        // P2a: carry the type-aware card content (file URLs, image pixel
        // dimensions) out of the body read that already happens here so the
        // card view can render useful file/image metadata without an extra
        // body read on the main thread.
        let fileURLs: [URL]
        let imageDimensions: CGSize?
        switch body {
        case let .files(urls):
            fileURLs = urls
            imageDimensions = nil
        case let .image(_, width, height), let .encryptedImage(_, width, height):
            fileURLs = []
            imageDimensions = CGSize(width: width, height: height)
        default:
            fileURLs = []
            imageDimensions = nil
        }
        return MacClippyHistoryEntry(
            meta: meta,
            contentKind: body.contentKind,
            preview: preview,
            fileURLs: fileURLs,
            imageDimensions: imageDimensions
        )
    }

    private func pasteboardContent(
        for record: ClipboardRecord,
        plain: Bool
    ) throws -> MacClippyPasteboardContent {
        switch record {
        case let .text(value):
            return .text(value)
        case let .html(value):
            let text = MacClippyClipboardText.plainText(from: record) ?? value
            return plain ? .text(text) : .html(value, plainText: text)
        case let .rtf(data):
            guard let text = MacClippyClipboardText.plainText(from: record) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return plain ? .text(text) : .rtf(data, plainText: text)
        case let .image(blobID, _, _), let .encryptedImage(blobID, _, _):
            return .image(try blobStore.read(id: blobID))
        case let .files(urls):
            return .files(urls)
        }
    }

    private func withStoreLock<T>(_ operation: () throws -> T) rethrows -> T {
        storeLock.lock()
        defer { storeLock.unlock() }
        return try operation()
    }

    private func measureDiagnosticMetric<T>(
        _ operation: String,
        _ work: () throws -> T
    ) rethrows -> T {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
            let milliseconds = min(elapsed / 1_000_000, UInt64(Int.max))
            MacClippyDiagnosticsRecorder.shared.recordMetric(
                operation: operation,
                durationMilliseconds: Int(milliseconds)
            )
        }
        return try work()
    }

    // Paste injection is the user-visible operation. Frequency is derived
    // metadata, so a database failure after the OS accepted the injected
    // paste must not turn a successful paste into a thrown/partial result.
    // Keep the failure observable and let the next maintenance/recovery path
    // handle the stale counter instead of silently swallowing it.
    private func recordSuccessfulPasteFrequency(for id: RecordID) {
        do {
            try withStoreLock {
                try clipboardStore.bumpFrequency(id: id)
            }
        } catch {
            MacClippyLog.record(
                category: .paste,
                code: .pasteMetadataUpdateFailed,
                operation: "paste_frequency_update",
                recoveryAction: "retry_paste_metadata_update",
                impact: "paste_succeeded_frequency_not_updated"
            )
        }
    }
}

private extension MacClippyCapturePayload {
    var imageData: Data? {
        if case let .image(data, _, _) = self { return data }
        return nil
    }
}
