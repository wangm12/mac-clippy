import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform
import SwiftUI

final class MacClippyCancellationToken: @unchecked Sendable {
    let lock = NSLock()
    var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

final class MacClippyDispatchWorkItem: @unchecked Sendable {
    let item: DispatchWorkItem

    init(_ item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}

final class MacClippyNotificationToken: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    func remove() {
        NotificationCenter.default.removeObserver(token)
    }
}

@MainActor
final class MacClippyDockModel: ObservableObject {
    @Published var query = "" {
        didSet {
            guard oldValue != query else { return }
            highlightTerms = MacClippySearchGrammar.parse(query).bareTerms
            if !selection.isEmpty || allSelectedRecordIDs != nil {
                invalidateAllSelectionScope()
            }
            scheduleSnippetFilter()
            scheduleReload()
        }
    }
    // Parsed once per query change so card highlight does not re-parse the
    // grammar on every carousel refresh.
    var highlightTerms: [String] = []

    @Published var historyItems: [MacClippyHistoryEntry] = []
    @Published var snippets: [MacClippySnippetEntry] = []
    @Published var filteredSnippets: [MacClippySnippetEntry] = []
    @Published var pinboards: [MacClippyPinboardEntry] = [] {
        didSet {
            rebuildCategoryMembershipIndex()
        }
    }
    var categoryMembershipsByItemID: [RecordID: [MacClippyDockCategoryPresentation]] = [:]
    // Pre-computed consecutive-duplicate run counts keyed by record ID, so the
    // card view reads an O(1) lookup instead of an O(n²) scan on every focus
    // change. Recomputed only when the visible list changes (reload/tab switch).
    @Published var dedupRunCounts: [RecordID: Int] = [:]
    @Published var selectedTab: MacClippyDockTab = .history
    @Published var isLoading = false
    // Keep failures scoped to the surface that can recover them. A copy or
    // preview failure must never replace an otherwise healthy history list.
    @Published var historyLoadError: String?
    @Published var pageError: String?
    @Published var previewError: String?
    @Published var actionError: String?

    /// Compatibility/readout surface used for accessibility announcements and
    /// diagnostics. Views should render the scoped error instead of this
    /// aggregate value.
    var errorMessage: String? {
        actionError ?? previewError ?? pageError ?? historyLoadError
    }

    func clearHistoryError() {
        historyLoadError = nil
    }

    func clearPageError() {
        pageError = nil
    }

    func clearPreviewError() {
        previewError = nil
    }

    func clearActionError() {
        actionError = nil
    }

    func clearAllErrors() {
        historyLoadError = nil
        pageError = nil
        previewError = nil
        actionError = nil
    }

    func setActionError(_ message: String) {
        actionError = message
    }

    func setPreviewError(_ message: String) {
        previewError = message
    }
    @Published var focusedIndex = 0
    /// Keyboard and preview navigation use this token to request a scroll into
    /// view. Pointer selection intentionally leaves it unchanged so clicking a
    /// card never recenters the carousel.
    @Published var focusFollowRequestID: UInt = 0
    /// Capture the item that caused the request. The view may receive the
    /// published token after another pointer selection has already changed
    /// focusedIndex, so resolving the target from the latest index could scroll
    /// the clicked card even though the click itself did not request a scroll.
    @Published var focusFollowTargetID: RecordID?
    // Mirrors the controller's Space-preview visibility so the card view can
    // render an active accent border on the focused card while previewing.
    // Toggled by the controller when the preview shows/hides.
    @Published var isPreviewVisible = false
    @Published var actionFeedback: MacClippyDockActionFeedback?
    @Published var modal: MacClippyDockModal?
    @Published var searchFocusRequest = 0
    @Published var searchFocusReset = 0
    /// P1 multi-select state. The selection is active only on the history and
    /// pinboard tabs (clipboard records); the snippets tab keeps the existing
    /// single-focus path because snippet multi-select has no real ordered
    /// multi-paste semantic in P1. The state is rebinding-cleaned on every
    /// reload and tab switch so it can never reference a deleted or filtered-
    /// out record.
    @Published var selection = MacClippyDockSelectionState()

    let runtime: MacClippyRuntime
    let workQueue = DispatchQueue(label: "com.macallyouneed.macclippy.dock", qos: .userInitiated)
    let reloadQueue = DispatchQueue(label: "com.macallyouneed.macclippy.reload", qos: .userInitiated)
    let previewQueue = DispatchQueue(label: "com.macallyouneed.macclippy.preview", qos: .userInitiated)
    let snippetFilterQueue = DispatchQueue(label: "com.macallyouneed.macclippy.snippet-filter", qos: .userInitiated)
    let thumbnailLoader: MacClippyCardThumbnailLoader
    var requestID = 0
    var reloadWorkItem: MacClippyDispatchWorkItem?
    var previewWorkItem: MacClippyDispatchWorkItem?
    var reloadCancellationToken: MacClippyCancellationToken?
    var previewCancellationToken: MacClippyCancellationToken?
    var detailsCancellationToken: MacClippyCancellationToken?
    var isSelecting = false
    var actionFeedbackTask: Task<Void, Never>?
    var reloadTask: Task<Void, Never>?
    var snippetFilterWorkItem: MacClippyDispatchWorkItem?
    var snippetFilterRequestID: UInt = 0
    var historyPageToken: MacClippyHistoryPageToken?
    var historyQuery = ""
    var historyHasMore = true
    var historyIsLoadingMore = false
    var historyLoadGeneration: UInt = 0
    var historyLoadWorkItem: MacClippyDispatchWorkItem?
    var historyLoadCancellationToken: MacClippyCancellationToken?
    var historyChangeObserver: MacClippyNotificationToken?
    var isSessionActive = false
    @Published var pinboardSearchItems: [MacClippyHistoryEntry] = []
    @Published var pinboardSearchIsLoading = false
    @Published var pinboardSearchError: String?
    var pinboardSearchBoardID: RecordID?
    var pinboardSearchQuery = ""
    var pinboardSearchPageToken: MacClippyPinboardSearchPageToken?
    var pinboardSearchHasMore = false
    var pinboardSearchGeneration: UInt = 0
    var pinboardSearchWorkItem: MacClippyDispatchWorkItem?
    var pinboardSearchCancellationToken: MacClippyCancellationToken?
    // Cmd+A can select records that are not loaded into the carousel yet. The
    // ordered ID list is kept separately from the visible selection state so
    // focus/navigation remain bounded to rendered cards while batch actions
    // still receive the complete selection.
    var allSelectedRecordIDs: [RecordID]?
    var allSelectedRecordIDSet: Set<RecordID>?
    var selectAllWorkItem: MacClippyDispatchWorkItem?
    var selectAllCancellationToken: MacClippyCancellationToken?
    var selectAllGeneration: UInt = 0
    // P1 stale-operation guard. `sessionGeneration` is bumped on dock show/hide
    // so an async completion from a previous dock session cannot mutate state
    // or close a newly reopened dock. `operationGeneration` is bumped on every
    // batch operation start so a slow earlier batch cannot overwrite the
    // result of a newer batch. Each async batch completion captures the
    // generation it was started with and no-ops if it no longer matches.
    var sessionGeneration: UInt = 0
    var operationGeneration: UInt = 0
    // Rename operations have their own generation because the inline editor can
    // save more than once without starting a batch operation. Only the newest
    // save in the current dock session may publish feedback or trigger a reload.
    var nameOperationGeneration: UInt = 0
    var modalPresentationToken: UInt = 0
    var pinboardLoadingIDs: Set<RecordID> = []
    var pinboardLoadGeneration: UInt = 0
    var pinboardItemPageRetryToken: MacClippyPinboardSearchPageToken?
    var queuePasteCancellationToken: MacClippyCancellationToken?
    var sideEffectGate: MacClippyPasteInjectionGate?

    struct Snapshot {
        let history: MacClippyHistoryPage
        let snippets: [MacClippySnippetEntry]?
        let pinboards: [MacClippyPinboardEntry]?
    }

    init(runtime: MacClippyRuntime) {
        self.runtime = runtime
        thumbnailLoader = MacClippyDockModel.makeThumbnailLoader(runtime: runtime)
        let observer = NotificationCenter.default.addObserver(
            forName: .macClippyHistoryDidChange,
            object: runtime,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleExternalHistoryChange()
            }
        }
        historyChangeObserver = MacClippyNotificationToken(observer)
    }

    func presentCreateCategory() {
        modalPresentationToken &+= 1
        modal = .createCategory(token: modalPresentationToken)
    }

    func presentRenameItem(for entry: MacClippyHistoryEntry) {
        modalPresentationToken &+= 1
        modal = .renameItem(recordID: entry.id, initialName: entry.customLabel, token: modalPresentationToken)
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
        historyChangeObserver?.remove()
        actionFeedbackTask?.cancel()
        reloadTask?.cancel()
        reloadWorkItem?.cancel()
        reloadCancellationToken?.cancel()
        previewWorkItem?.cancel()
        previewCancellationToken?.cancel()
        detailsCancellationToken?.cancel()
        queuePasteCancellationToken?.cancel()
        snippetFilterWorkItem?.cancel()
        historyLoadWorkItem?.cancel()
        historyLoadCancellationToken?.cancel()
        pinboardSearchWorkItem?.cancel()
        pinboardSearchCancellationToken?.cancel()
        selectAllWorkItem?.cancel()
        selectAllCancellationToken?.cancel()
        thumbnailLoader.queue.cancelAllOperations()
    }
}
