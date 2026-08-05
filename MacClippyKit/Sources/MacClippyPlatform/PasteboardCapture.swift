import AppKit
import Foundation

import MacClippyCore

public struct MacClippyPasteboardItem: Equatable, Sendable {
    public let types: [String]
    public let representations: [String: Data]
    public let oversizedTypes: Set<String>

    public init(
        types: [String],
        representations: [String: Data] = [:],
        oversizedTypes: Set<String> = []
    ) {
        self.types = types
        self.representations = representations
        self.oversizedTypes = oversizedTypes
    }

    public func data(forType type: String) -> Data? {
        representations[type]
    }

    public func string(forType type: String) -> String? {
        guard let data = data(forType: type) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public typealias PasteboardItem = MacClippyPasteboardItem

public struct MacClippyPasteboardChange: Equatable, Sendable {
    public let changeCount: Int
    public let items: [PasteboardItem]
    public let sourceAppBundleID: String?
    public let truncatedItemCount: Int

    public init(
        changeCount: Int,
        items: [PasteboardItem],
        sourceAppBundleID: String? = nil,
        truncatedItemCount: Int = 0
    ) {
        self.changeCount = changeCount
        self.items = items
        self.sourceAppBundleID = sourceAppBundleID
        self.truncatedItemCount = max(0, truncatedItemCount)
    }

    public var pasteboardTypes: [String] {
        Array(Set(items.flatMap(\.types))).sorted()
    }
}

public typealias PasteboardChange = MacClippyPasteboardChange

public protocol MacClippyPasteboardReading: AnyObject {
    // Production readers override this with the cheap generation-counter
    // lookup. The default keeps injected readers source-compatible.
    func currentChangeCount() -> Int
    func read() -> PasteboardChange
    // Re-reads the previously-unavailable types for the same changeCount from
    // the underlying pasteboard and returns an updated change. The default
    // implementation returns the change unchanged, so injected test readers
    // that do not model lazy providers keep working without modification.
    // The system reader overrides this to actually re-query NSPasteboardItem
    // for the specific (itemIndex, uti) pairs the retry state is tracking.
    func reread(change: PasteboardChange, unavailableTypes: [(itemIndex: Int, uti: String)]) -> PasteboardChange
}

public extension MacClippyPasteboardReading {
    func currentChangeCount() -> Int {
        read().changeCount
    }

    func reread(change: PasteboardChange, unavailableTypes: [(itemIndex: Int, uti: String)]) -> PasteboardChange {
        change
    }
}

public typealias PasteboardReading = MacClippyPasteboardReading

public final class MacClippySystemPasteboardReader: PasteboardReading {
    private let pasteboard: NSPasteboard
    private let sourceAppBundleID: () -> String?
    private let inputLimits: MacClippyPasteboardInputLimits

    public init(
        pasteboard: NSPasteboard = .general,
        sourceAppBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        inputLimits: MacClippyPasteboardInputLimits = .default
    ) {
        self.pasteboard = pasteboard
        self.sourceAppBundleID = sourceAppBundleID
        self.inputLimits = inputLimits
    }

    public func currentChangeCount() -> Int {
        pasteboard.changeCount
    }

    public func read() -> PasteboardChange {
        let allItems = pasteboard.pasteboardItems ?? []
        var totalBytes = 0
        let items = allItems.prefix(inputLimits.maxItemsPerChange).map { item in
            let types = item.types.map(\.rawValue)
            var representations: [String: Data] = [:]
            var oversizedTypes = Set<String>()
            let boundedTypes = item.types.prefix(inputLimits.maxRepresentationsPerItem)
            for type in boundedTypes {
                let key = type.rawValue
                // Retry lazy pasteboard data that is temporarily unavailable.
                // If a provider returns more than the per-representation or
                // per-change budget, retain only a type marker and never
                // encrypt/index/write the bytes.
                if let data = MacClippyPasteboardReadRetry.read({ item.data(forType: type) }) {
                    if accept(data, for: key, totalBytes: &totalBytes) {
                        representations[key] = data
                    } else {
                        oversizedTypes.insert(key)
                    }
                } else if let string = MacClippyPasteboardReadRetry.read({ item.string(forType: type) }) {
                    let data = Data(string.utf8)
                    if accept(data, for: key, totalBytes: &totalBytes) {
                        representations[key] = data
                    } else {
                        oversizedTypes.insert(key)
                    }
                }
            }
            for type in item.types.dropFirst(inputLimits.maxRepresentationsPerItem) {
                oversizedTypes.insert(type.rawValue)
            }
            return PasteboardItem(types: types, representations: representations, oversizedTypes: oversizedTypes)
        }
        return PasteboardChange(
            changeCount: pasteboard.changeCount,
            items: items,
            sourceAppBundleID: sourceAppBundleID(),
            truncatedItemCount: max(0, allItems.count - items.count)
        )
    }

    // Cross-poll re-read for lazy provider data. Re-queries only the
    // previously-unavailable (itemIndex, uti) pairs and merges any newly-
    // available bytes into a copy of the original change. Types that are
    // still unavailable after this re-read remain absent in the returned
    // change's representations; the observer will mark them .unavailable at
    // the mapping layer once the retry budget is exhausted.
    public func reread(change: PasteboardChange, unavailableTypes: [(itemIndex: Int, uti: String)]) -> PasteboardChange {
        guard !unavailableTypes.isEmpty else { return change }
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        var updatedItems = change.items
        for pending in unavailableTypes {
            guard pending.itemIndex < updatedItems.count else { continue }
            let item = updatedItems[pending.itemIndex]
            guard pasteboardItems.indices.contains(pending.itemIndex) else { continue }
            let nsItem = pasteboardItems[pending.itemIndex]
            let nsType = NSPasteboard.PasteboardType(rawValue: pending.uti)
            var representations = item.representations
            var oversizedTypes = item.oversizedTypes
            var currentTotalBytes = totalBytes(in: updatedItems)
            if let data = MacClippyPasteboardReadRetry.read({ nsItem.data(forType: nsType) }) {
                if accept(data, for: pending.uti, totalBytes: &currentTotalBytes) {
                    representations[pending.uti] = data
                    oversizedTypes.remove(pending.uti)
                } else {
                    oversizedTypes.insert(pending.uti)
                }
            } else if let string = MacClippyPasteboardReadRetry.read({ nsItem.string(forType: nsType) }) {
                let data = Data(string.utf8)
                if accept(data, for: pending.uti, totalBytes: &currentTotalBytes) {
                    representations[pending.uti] = data
                    oversizedTypes.remove(pending.uti)
                } else {
                    oversizedTypes.insert(pending.uti)
                }
            }
            updatedItems[pending.itemIndex] = PasteboardItem(
                types: item.types,
                representations: representations,
                oversizedTypes: oversizedTypes
            )
        }
        return PasteboardChange(
            changeCount: change.changeCount,
            items: updatedItems,
            sourceAppBundleID: change.sourceAppBundleID,
            truncatedItemCount: change.truncatedItemCount
        )
    }

    private func accept(_ data: Data, for _: String, totalBytes: inout Int) -> Bool {
        guard data.count <= inputLimits.maxRepresentationBytes else { return false }
        guard totalBytes <= inputLimits.maxChangeBytes - data.count else { return false }
        totalBytes += data.count
        return true
    }

    private func totalBytes(in items: [PasteboardItem]) -> Int {
        items.reduce(0) { total, item in total + item.representations.values.reduce(0) { $0 + $1.count } }
    }
}

public typealias SystemPasteboardReader = MacClippySystemPasteboardReader

// Dedicated serial queue label for the production PasteboardObserver.
// The observer polls and re-reads every advertised UTI here, and the
// synchronous retry helper's sleeps run on this queue, so neither can block
// the main thread. The handler still hands the change to the caller's
// capture queue (see MacClippyRuntime), so persistence stays off this queue
// too. Tests inject their own queue, so this default only affects production.
public extension MacClippyPasteboardObserver {
    static let productionPollQueueLabel = "com.macallyouneed.macclippy.pasteboard.poll"
}

public final class MacClippyPasteboardObserver {
    public typealias Handler = (PasteboardChange) -> Void

    private let reader: PasteboardReading
    private var exclusionRules: MacClippyCore.CaptureExclusionRules
    private var capturePaused = false
    private let writeSentinel: MacClippyPasteboardWriteSentinel?
    private let pollInterval: TimeInterval
    private let queue: DispatchQueue
    private let lifecycleKey = DispatchSpecificKey<Void>()
    private let retryState: MacClippyPasteboardReadRetryState
    private var timer: DispatchSourceTimer?
    private var handler: Handler?
    private var lastChangeCount: Int?

    public init(
        reader: PasteboardReading = SystemPasteboardReader(),
        exclusionRules: MacClippyCore.CaptureExclusionRules = MacClippyCore.CaptureExclusionRules(),
        writeSentinel: MacClippyPasteboardWriteSentinel? = nil,
        pollInterval: TimeInterval = 0.25,
        // Production default: a dedicated serial utility queue (NOT the main
        // queue) so polling and the synchronous retry helper's sleeps never
        // block the UI. Persistence is handed off to the caller's capture
        // queue from the handler, so this queue only carries poll/read work.
        // Tests inject an explicit queue (e.g. .main or a sync test queue)
        // for deterministic, in-process delivery.
        queue: DispatchQueue = DispatchQueue(
            label: MacClippyPasteboardObserver.productionPollQueueLabel,
            qos: .userInitiated
        ),
        retryState: MacClippyPasteboardReadRetryState = MacClippyPasteboardReadRetryState()
    ) {
        self.reader = reader
        self.exclusionRules = exclusionRules
        self.writeSentinel = writeSentinel
        self.pollInterval = max(0.01, pollInterval)
        self.queue = queue
        self.retryState = retryState
        queue.setSpecific(key: lifecycleKey, value: ())
    }

    /// Updates capture exclusions without restarting the polling timer. The
    /// settings UI can call this from the main thread; the update is queued
    /// onto the same serial executor as polling so it never races delivery or
    /// blocks the caller behind a provider read.
    public func updateExclusionRules(_ rules: MacClippyCore.CaptureExclusionRules) {
        enqueueOnLifecycleQueue { [weak self] in
            self?.exclusionRules = rules
        }
    }

    public func setCapturePaused(_ paused: Bool) {
        enqueueOnLifecycleQueue { [weak self] in
            self?.capturePaused = paused
        }
    }

    deinit {
        stop()
    }

    public func start(handler: @escaping Handler) {
        onLifecycleQueue { [weak self] in
            guard let self else { return }
            self.stopOnLifecycleQueue()
            self.handler = handler
            self.lastChangeCount = self.reader.currentChangeCount()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval)
            timer.setEventHandler { [weak self] in self?.pollOnLifecycleQueue() }
            self.timer = timer
            timer.resume()
        }
    }

    // Cancels the timer and drops the handler. Also clears cross-poll retry
    // state and resets the write sentinel's pending tokens so a subsequent
    // start() never inherits stale state from a previous session. Safe to
    // call from any thread: retryState and the sentinel are lock-protected,
    // and the timer/handler handoff is ordered so an in-flight poll() on the
    // observer's queue either completes before the clear or sees the cleared
    // state under the locks.
    public func stop() {
        onLifecycleQueue { [weak self] in
            self?.stopOnLifecycleQueue()
        }
    }

    public func poll() {
        onLifecycleQueue { [weak self] in
            self?.pollOnLifecycleQueue()
        }
    }

    private func onLifecycleQueue(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: lifecycleKey) != nil {
            operation()
        } else {
            queue.sync(execute: operation)
        }
    }

    private func enqueueOnLifecycleQueue(_ operation: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: lifecycleKey) != nil {
            operation()
        } else {
            queue.async(execute: operation)
        }
    }

    private func stopOnLifecycleQueue() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        handler = nil
        retryState.clearAll()
        writeSentinel?.reset()
    }

    private func pollOnLifecycleQueue() {
        let observedChangeCount = reader.currentChangeCount()
        let paused = capturePaused

        if paused {
            retryState.clear(changeCount: observedChangeCount)
            lastChangeCount = observedChangeCount
            return
        }

        // Suppress only exact internal writes originating from Mac Clippy.
        // The sentinel consumes the token on first match so a later external
        // write is never hidden. External content (including concealed,
        // transient, custom, and unknown UTIs) is never filtered here.
        if let writeSentinel, writeSentinel.consume(changeCount: observedChangeCount) {
            retryState.clear(changeCount: observedChangeCount)
            lastChangeCount = observedChangeCount
            return
        }

        // Cross-poll retry for lazy provider data. When a new changeCount
        // arrives with advertised-but-unavailable UTIs, withhold
        // lastChangeCount advancement (and thus delivery) and record the
        // pending types so subsequent polls can re-read them. After the retry
        // budget, deliver the change with every still-unavailable advertised
        // UTI carried as an .unavailable marker instead of dropping the type.
        if let pending = retryState.pending(for: observedChangeCount) {
            let change = pending.originalChange ?? reader.read()
            let changeCount = change.changeCount
            let reread = reader.reread(change: change, unavailableTypes: pending.unavailableTypes)
            guard reader.currentChangeCount() == changeCount else {
                // The provider reread crossed a new pasteboard generation.
                // Never deliver bytes from the old generation; the next poll
                // will materialize the new change from scratch.
                retryState.clear(changeCount: changeCount)
                return
            }
            let stillUnavailable = MacClippyPasteboardAvailability.unavailableTypes(in: reread)
            if stillUnavailable.isEmpty {
                retryState.clear(changeCount: changeCount)
                deliver(reread, changeCount: changeCount)
                return
            }
            retryState.updateUnavailableTypes(
                for: changeCount,
                unavailableTypes: stillUnavailable
            )
            let hasBudget = retryState.incrementAttempts(for: changeCount)
            if hasBudget {
                // Keep waiting for the provider to materialize the remaining
                // lazy bytes; do not advance lastChangeCount yet.
                return
            }
            // Budget exhausted: deliver with unavailable markers and clear.
            retryState.clear(changeCount: changeCount)
            deliver(reread, changeCount: changeCount)
            return
        }

        guard lastChangeCount != observedChangeCount else { return }

        // The generation changed, so pay the cost of materializing all
        // advertised representations exactly once for this poll.
        let change = reader.read()
        let changeCount = change.changeCount
        guard lastChangeCount != changeCount else { return }
        guard reader.currentChangeCount() == changeCount else {
            // A pasteboard write raced the materialization. Discard this
            // snapshot and let the next poll read the current generation.
            return
        }

        let unavailable = MacClippyPasteboardAvailability.unavailableTypes(in: change)
        if !unavailable.isEmpty {
            // Seed the retry state and spend the first attempt. If the budget
            // is already exhausted (maxAttempts == 1), deliver immediately
            // with unavailable markers so the advertised types are retained.
            retryState.record(change: change, unavailableTypes: unavailable)
            let hasBudget = retryState.incrementAttempts(for: changeCount)
            if hasBudget {
                return
            }
            retryState.clear(changeCount: changeCount)
        }

        deliver(change, changeCount: changeCount)
    }

    private func deliver(_ change: PasteboardChange, changeCount: Int) {
        lastChangeCount = changeCount
        // Drop any retry state for older changeCounts; they can never be
        // observed again because changeCount is monotonic per pasteboard.
        for pendingChangeCount in retryState.stalePendingChangeCounts(below: changeCount) {
            retryState.clear(changeCount: pendingChangeCount)
        }
        let rules = exclusionRules

        let textExcluded = !rules.excludedTextPatterns.isEmpty
            && MacClippyCaptureMapper.payload(for: change)?.searchableText.map(rules.shouldExcludeText) == true

        guard !change.items.isEmpty,
              !rules.shouldExclude(
                  appBundleID: change.sourceAppBundleID,
                  pasteboardTypes: change.pasteboardTypes
              ),
              !textExcluded else { return }
        handler?(change)
    }
}

public typealias PasteboardObserver = MacClippyPasteboardObserver
