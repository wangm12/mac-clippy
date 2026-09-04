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
    // Production readers can observe lifecycle cancellation between items and
    // provider retries. Injected readers keep the source-compatible default.
    func read(shouldContinue: () -> Bool) -> PasteboardChange
    // Re-reads the previously-unavailable types for the same changeCount from
    // the underlying pasteboard and returns an updated change. The default
    // implementation returns the change unchanged, so injected test readers
    // that do not model lazy providers keep working without modification.
    // The system reader overrides this to actually re-query NSPasteboardItem
    // for the specific (itemIndex, uti) pairs the retry state is tracking.
    func reread(change: PasteboardChange, unavailableTypes: [(itemIndex: Int, uti: String)]) -> PasteboardChange
    func reread(
        change: PasteboardChange,
        unavailableTypes: [(itemIndex: Int, uti: String)],
        shouldContinue: () -> Bool
    ) -> PasteboardChange
    /// Reads a specific pasteboard generation when the reader still has it.
    /// System NSPasteboard only retains the current generation, so the default
    /// returns nil for any count other than `currentChangeCount()`.
    func read(changeCount: Int, shouldContinue: () -> Bool) -> PasteboardChange?
}

public extension MacClippyPasteboardReading {
    func currentChangeCount() -> Int {
        read().changeCount
    }

    func read(shouldContinue: () -> Bool) -> PasteboardChange {
        read()
    }

    func reread(change: PasteboardChange, unavailableTypes: [(itemIndex: Int, uti: String)]) -> PasteboardChange {
        change
    }

    func reread(
        change: PasteboardChange,
        unavailableTypes: [(itemIndex: Int, uti: String)],
        shouldContinue: () -> Bool
    ) -> PasteboardChange {
        reread(change: change, unavailableTypes: unavailableTypes)
    }

    func read(changeCount: Int, shouldContinue: () -> Bool) -> PasteboardChange? {
        guard currentChangeCount() == changeCount else { return nil }
        let change = read(shouldContinue: shouldContinue)
        guard change.changeCount == changeCount else { return nil }
        return change
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
        read(shouldContinue: { true })
    }

    public func read(shouldContinue: () -> Bool) -> PasteboardChange {
        let allItems = pasteboard.pasteboardItems ?? []
        var totalBytes = 0
        var items: [PasteboardItem] = []
        items.reserveCapacity(min(allItems.count, inputLimits.maxItemsPerChange))
        for item in allItems.prefix(inputLimits.maxItemsPerChange) {
            guard shouldContinue() else { return PasteboardChange(changeCount: pasteboard.changeCount, items: [], sourceAppBundleID: nil) }
            var types: [String] = []
            var boundedTypes: [NSPasteboard.PasteboardType] = []
            var hasTruncatedTypes = false
            for type in item.types {
                guard type.rawValue.utf8.count <= inputLimits.maxUTIBytes,
                      boundedTypes.count < inputLimits.maxRepresentationsPerItem else {
                    hasTruncatedTypes = true
                    continue
                }
                types.append(type.rawValue)
                boundedTypes.append(type)
            }
            if hasTruncatedTypes {
                types.append(MacClippyPasteboardInputLimits.truncatedUTIMarker)
            }
            var representations: [String: Data] = [:]
            var oversizedTypes = Set<String>()
            for type in boundedTypes {
                guard shouldContinue() else { return PasteboardChange(changeCount: pasteboard.changeCount, items: [], sourceAppBundleID: nil) }
                let key = type.rawValue
                // Retry lazy pasteboard data that is temporarily unavailable.
                // If a provider returns more than the per-representation or
                // per-change budget, retain only a type marker and never
                // encrypt/index/write the bytes.
                if let data = MacClippyPasteboardReadRetry.read(shouldContinue: shouldContinue, { item.data(forType: type) }) {
                    if accept(data, for: key, totalBytes: &totalBytes) {
                        representations[key] = data
                    } else {
                        oversizedTypes.insert(key)
                    }
                } else if let string = MacClippyPasteboardReadRetry.read(shouldContinue: shouldContinue, { item.string(forType: type) }) {
                    let data = Data(string.utf8)
                    if accept(data, for: key, totalBytes: &totalBytes) {
                        representations[key] = data
                    } else {
                        oversizedTypes.insert(key)
                    }
                }
            }
            if hasTruncatedTypes {
                oversizedTypes.insert(MacClippyPasteboardInputLimits.truncatedUTIMarker)
            }
            items.append(PasteboardItem(types: types, representations: representations, oversizedTypes: oversizedTypes))
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
        reread(change: change, unavailableTypes: unavailableTypes, shouldContinue: { true })
    }

    public func reread(
        change: PasteboardChange,
        unavailableTypes: [(itemIndex: Int, uti: String)],
        shouldContinue: () -> Bool
    ) -> PasteboardChange {
        guard !unavailableTypes.isEmpty else { return change }
        let pasteboardItems = pasteboard.pasteboardItems ?? []
        var updatedItems = change.items
        for pending in unavailableTypes {
            guard shouldContinue() else { return change }
            guard pending.itemIndex < updatedItems.count else { continue }
            let item = updatedItems[pending.itemIndex]
            guard pasteboardItems.indices.contains(pending.itemIndex) else { continue }
            let nsItem = pasteboardItems[pending.itemIndex]
            let nsType = NSPasteboard.PasteboardType(rawValue: pending.uti)
            var representations = item.representations
            var oversizedTypes = item.oversizedTypes
            var currentTotalBytes = totalBytes(in: updatedItems)
            if let data = MacClippyPasteboardReadRetry.read(shouldContinue: shouldContinue, { nsItem.data(forType: nsType) }) {
                if accept(data, for: pending.uti, totalBytes: &currentTotalBytes) {
                    representations[pending.uti] = data
                    oversizedTypes.remove(pending.uti)
                } else {
                    oversizedTypes.insert(pending.uti)
                }
            } else if let string = MacClippyPasteboardReadRetry.read(shouldContinue: shouldContinue, { nsItem.string(forType: nsType) }) {
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

// SAFETY: lifecycle state is owned by the observer's serial queue and the
// transition lock protects generation checks made from other threads. The
// explicit annotation lets callers coordinate start/stop from concurrent
// lifecycle tests without treating the observer as an unowned value.
public final class MacClippyPasteboardObserver: @unchecked Sendable {
    public typealias Handler = (PasteboardChange) -> Void
    public typealias ProjectionHandler = (PasteboardChange, MacClippyCaptureProjection) -> Void

    let reader: PasteboardReading
    var exclusionRules: MacClippyCore.CaptureExclusionRules
    var capturePaused = false
    var ignoreNextCopyCount = 0
    var pollingSuspended = false
    let writeSentinel: MacClippyPasteboardWriteSentinel?
    var pollInterval: TimeInterval
    var pollActivity: MacClippyPasteboardPollActivity = .foreground
    let queue: DispatchQueue
    let lifecycleKey = DispatchSpecificKey<Void>()
    let retryState: MacClippyPasteboardReadRetryState
    let diagnosticsRecorder: MacClippyDiagnosticsRecorder
    let lifecycleStateLock = NSLock()
    var lifecycleGeneration: UInt64 = 0
    var lifecycleStarted = false
    var timer: DispatchSourceTimer?
    var projectionHandler: ProjectionHandler?
    var lastChangeCount: Int?
    var lastObservedChangeAt: Date?
    let secondsSinceLastUserInput: () -> TimeInterval
    let now: () -> Date

    public init(
        reader: PasteboardReading = SystemPasteboardReader(),
        exclusionRules: MacClippyCore.CaptureExclusionRules = MacClippyCore.CaptureExclusionRules(),
        writeSentinel: MacClippyPasteboardWriteSentinel? = nil,
        pollInterval: TimeInterval = 0.05,
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
        retryState: MacClippyPasteboardReadRetryState = MacClippyPasteboardReadRetryState(),
        diagnosticsRecorder: MacClippyDiagnosticsRecorder = .shared,
        secondsSinceLastUserInput: @escaping () -> TimeInterval = {
            MacClippyUserInputIdle.secondsSinceLastInput()
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.reader = reader
        self.exclusionRules = exclusionRules
        self.writeSentinel = writeSentinel
        self.pollInterval = max(0.01, pollInterval)
        self.queue = queue
        self.retryState = retryState
        self.diagnosticsRecorder = diagnosticsRecorder
        self.secondsSinceLastUserInput = secondsSinceLastUserInput
        self.now = now
        queue.setSpecific(key: lifecycleKey, value: ())
    }

    deinit {
        stop()
    }
}

public typealias PasteboardObserver = MacClippyPasteboardObserver
