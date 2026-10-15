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

public struct MacClippyPasteboardReadFailure: Equatable, Sendable {
    public let operation: String
    public let message: String

    public init(operation: String, message: String) {
        self.operation = String(operation.prefix(128))
        self.message = String(message.prefix(256))
    }

    public init(error: Error) {
        if let nativeError = error as? MacClippyObjectiveCException {
            self.init(operation: nativeError.operation, message: nativeError.localizedDescription)
        } else if let malformed = error as? MacClippyMalformedNativePasteboardResult {
            self.init(operation: malformed.operation, message: malformed.localizedDescription)
        } else {
            self.init(
                operation: String(describing: type(of: error)),
                message: error.localizedDescription
            )
        }
    }
}

public enum MacClippyPasteboardReadOutcome: Equatable, Sendable {
    case success(PasteboardChange)
    case failed(MacClippyPasteboardReadFailure)
    case cancelled
    case generationUnavailable
}

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
    /// Outcome-aware production read. The default keeps older injected readers
    /// source compatible; native readers override it to preserve failures.
    func readOutcome(shouldContinue: () -> Bool) -> MacClippyPasteboardReadOutcome
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
    func rereadOutcome(
        change: PasteboardChange,
        unavailableTypes: [(itemIndex: Int, uti: String)],
        shouldContinue: () -> Bool
    ) -> MacClippyPasteboardReadOutcome
    /// Reads a specific pasteboard generation when the reader still has it.
    /// System NSPasteboard only retains the current generation, so the default
    /// returns nil for any count other than `currentChangeCount()`.
    func read(changeCount: Int, shouldContinue: () -> Bool) -> PasteboardChange?
    func readOutcome(changeCount: Int, shouldContinue: () -> Bool) -> MacClippyPasteboardReadOutcome
}

public extension MacClippyPasteboardReading {
    func currentChangeCount() -> Int {
        read().changeCount
    }

    func read(shouldContinue: () -> Bool) -> PasteboardChange {
        read()
    }

    func readOutcome(shouldContinue: () -> Bool) -> MacClippyPasteboardReadOutcome {
        guard shouldContinue() else { return .cancelled }
        return .success(read(shouldContinue: shouldContinue))
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

    func rereadOutcome(
        change: PasteboardChange,
        unavailableTypes: [(itemIndex: Int, uti: String)],
        shouldContinue: () -> Bool
    ) -> MacClippyPasteboardReadOutcome {
        guard shouldContinue() else { return .cancelled }
        return .success(reread(
            change: change,
            unavailableTypes: unavailableTypes,
            shouldContinue: shouldContinue
        ))
    }

    func read(changeCount: Int, shouldContinue: () -> Bool) -> PasteboardChange? {
        guard currentChangeCount() == changeCount else { return nil }
        let change = read(shouldContinue: shouldContinue)
        guard change.changeCount == changeCount else { return nil }
        return change
    }

    func readOutcome(changeCount: Int, shouldContinue: () -> Bool) -> MacClippyPasteboardReadOutcome {
        guard shouldContinue() else { return .cancelled }
        guard let change = read(changeCount: changeCount, shouldContinue: shouldContinue) else {
            return shouldContinue() ? .generationUnavailable : .cancelled
        }
        return .success(change)
    }
}

public typealias PasteboardReading = MacClippyPasteboardReading

/// A one-shot reservation that follows a materialized pasteboard change from
/// observer delivery through persistence. The observer releases it
/// automatically if filtering or projection prevents the runtime handler from
/// taking ownership; runtime callers finish it only after retained payloads
/// have been cleared.
public final class MacClippyPasteboardCaptureAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var finishHandler: (@Sendable (Bool) -> Void)?

    public init(finish: @escaping @Sendable (Bool) -> Void) {
        finishHandler = finish
    }

    public func finish(wasPersisted: Bool) {
        lock.lock()
        let handler = finishHandler
        finishHandler = nil
        lock.unlock()
        handler?(wasPersisted)
    }

    deinit {
        finish(wasPersisted: false)
    }
}

public final class MacClippySystemPasteboardReader: PasteboardReading {
    let pasteboard: NSPasteboard
    let sourceAppBundleID: () -> String?
    let inputLimits: MacClippyPasteboardInputLimits
    let accessCoordinator: MacClippyPasteboardAccessCoordinator
    let onReadFailure: @Sendable (MacClippyObjectiveCException) -> Void
    private let lastChangeCountLock = NSLock()
    private var lastKnownChangeCount = 0

    public init(
        pasteboard: NSPasteboard = .general,
        sourceAppBundleID: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        inputLimits: MacClippyPasteboardInputLimits = .default,
        accessCoordinator: MacClippyPasteboardAccessCoordinator? = nil,
        onReadFailure: @escaping @Sendable (MacClippyObjectiveCException) -> Void = { _ in }
    ) {
        self.pasteboard = pasteboard
        self.sourceAppBundleID = sourceAppBundleID
        self.inputLimits = inputLimits
        self.accessCoordinator = accessCoordinator ?? .shared(for: pasteboard)
        self.onReadFailure = onReadFailure
    }

    public func currentChangeCount() -> Int {
        accessCoordinator.withAccess {
            do {
                let value = try MacClippyNativePasteboard.changeCount(of: pasteboard)
                rememberChangeCount(value)
                return value
            } catch let error as MacClippyObjectiveCException {
                onReadFailure(error)
                return rememberedChangeCount()
            } catch {
                return rememberedChangeCount()
            }
        }
    }

    func rememberChangeCount(_ value: Int) {
        lastChangeCountLock.lock()
        lastKnownChangeCount = value
        lastChangeCountLock.unlock()
    }

    func rememberedChangeCount() -> Int {
        lastChangeCountLock.lock()
        defer { lastChangeCountLock.unlock() }
        return lastKnownChangeCount
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
    public typealias AdmissionHandler = (PasteboardChange) -> MacClippyPasteboardCaptureAdmission?
    public typealias AdmittedProjectionHandler = (
        PasteboardChange,
        MacClippyCaptureProjection,
        MacClippyPasteboardCaptureAdmission
    ) -> Void

    let reader: PasteboardReading
    var exclusionRules: MacClippyCore.CaptureExclusionRules
    let textRulePreparationQueue: DispatchQueue
    var textRulePreparationToken: MacClippyTextRulePreparationToken?
    var capturePaused = false
    var ignoreNextCopyCount = 0
    var restartIgnoreNextCopyDisposition = false
    var pollingSuspended = false
    package var automaticPollingEnabled = true
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
    var admissionHandler: AdmissionHandler?
    var admittedProjectionHandler: AdmittedProjectionHandler?
    var recoveryReadRequested = false
    static let maximumRecoveryReadWaiters = 32
    var recoveryReadCompletions: [(Int?) -> Void] = []
    var recoverySuppressedChangeCount: Int?
    static let maximumReadFailureAttempts = 3
    var failedReadChangeCount: Int?
    var failedReadAttempts = 0
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
        textRulePreparationQueue: DispatchQueue = DispatchQueue(
            label: "com.macallyouneed.macclippy.capture.text-rules.prepare",
            qos: .utility
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
        self.textRulePreparationQueue = textRulePreparationQueue
        self.retryState = retryState
        self.diagnosticsRecorder = diagnosticsRecorder
        self.secondsSinceLastUserInput = secondsSinceLastUserInput
        self.now = now
        queue.setSpecific(key: lifecycleKey, value: ())
        enqueueOnLifecycleQueue { [weak self] in
            self?.prepareTextExclusionsOnLifecycleQueue()
        }
    }

    deinit {
        textRulePreparationToken?.cancel()
        timer?.setEventHandler {}
        timer?.cancel()
        retryState.clearAll()
        let completions = recoveryReadCompletions
        recoveryReadCompletions.removeAll()
        completions.forEach { $0(nil) }
    }
}

public typealias PasteboardObserver = MacClippyPasteboardObserver
