import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation
import os.signpost

import MacClippyCore
import MacClippyPlatform

extension Notification.Name {
    static let macClippyHistoryDidChange = Notification.Name(
        "com.macallyouneed.macclippy.historyDidChange"
    )
}

private let macClippyRuntimePerformanceLog = OSLog(
    subsystem: "com.macallyouneed.macclippy",
    category: "performance"
)

// The runtime is deliberately shared by the AppKit main actor, the dedicated
// capture queue, OCR tasks, and the observer queue. All mutable runtime state
// is either protected by `storeLock`, an owned serial queue, or an
// independently synchronized collaborator. Keep this annotation until the
// stores can be expressed as actors without changing the synchronous AppKit
// APIs; new cross-queue access must go through those boundaries.
// SAFETY: `storeLock` serializes synchronous store operations; `captureQueue`
// owns capture work and `maintenanceQueue` owns reconciliation/retention; the
// observer, snippet snapshot, sentinel, and
// diagnostics recorder each have their own lifecycle/synchronization boundary.
// `lifecycleLock` serializes start/stop/permission refresh so a stop cannot
// interleave between the running-state transition and observer/timer setup.
// `MacClippyRuntimeConcurrencyTests` exercises concurrent history/label access
// while this remains a synchronous AppKit-facing API.
final class MacClippyRuntime: @unchecked Sendable {
    let clipboardStore: ClipboardStore
    let searchStore: SearchStore
    let pinboardStore: PinboardStore
    let snippetStore: SnippetStore
    let databases: [MacClippyDatabase]
    let paths: MacClippyPaths
    let blobStore: BlobStore
    let thumbnailDiskCache: MacClippyThumbnailDiskCache
    let observer: PasteboardObserver
    let snippetExpander: MacClippySnippetExpander
    let snippetLookupSnapshot: MacClippySnippetLookupSnapshot
    let preferencesDefaults: UserDefaults
    let retentionPolicyOverride: RetentionPolicy?
    let historyEntryCache = NSCache<NSString, MacClippyHistoryEntryCacheBox>()
    let storeLock = NSLock()
    let searchScopeOwnerID = UUID()
    static let storeLockHeldThreadKey = "MacClippy.storeLockHeld"
    #if DEBUG
    let storeLockMetricsLock = NSLock()
    var storeLockAcquisitionCountValue = 0
    var blobReadsWhileStoreLockHeldValue = 0
    var afterImageBlobLeaseAcquiredForTesting: ((String) -> Void)?
    // Set under storeLock. Allows update preflight reads to fail deterministically.
    var snippetUpdateListForTesting: (() throws -> [Snippet])?
    #endif
    // Shared sentinel so Mac Clippy's own copy/paste/snippet writes are
    // suppressed by the observer without filtering any external content.
    private let writeSentinel: MacClippyPasteboardWriteSentinel
    // Shared injector that stamps every copy/paste/snippet write with the
    // sentinel so the observer can skip recapture of Mac Clippy's own writes.
    // Injectable so regression tests can assert Copy all prepares the
    // pasteboard without posting a paste keystroke; production and existing
    // tests use the default sentinel-bound injector.
    let pasteInjector: MacClippyPasteInjector
    // Off-main queue for capture mapping, encryption, blob writes, and DB
    // persistence. The observer polls on its own queue and hands the change
    // here so the main thread never blocks on capture.
    let captureQueue = DispatchQueue(
        label: "com.macallyouneed.macclippy.capture",
        qos: .userInitiated
    )
    let captureQueueAdmission = MacClippyCaptureQueueAdmission()
    let captureQueueKey = DispatchSpecificKey<Void>()
    // Storage reconciliation and retention are bounded, cancellable
    // maintenance work. Keep them off the capture queue so a large history or
    // FTS repair cannot delay the next pasteboard change.
    let maintenanceQueue = DispatchQueue(
        label: "com.macallyouneed.macclippy.maintenance",
        qos: .utility
    )
    let maintenanceQueueKey = DispatchSpecificKey<Void>()
    // Vision is expensive and image capture can arrive in bursts. Keep only a
    // small amount of OCR work queued and run at most two recognizers at once;
    // OCR is an enrichment pass, so dropping excess work is safer than
    // retaining an unbounded set of large image Data values.
    let ocrQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.macallyouneed.macclippy.ocr"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = MacClippyOCRSchedulePolicy.maxConcurrentRecognizers
        return queue
    }()
    var pendingOCRJobs = 0
    var pendingOCRBytes = 0
    // These reservations cover retained OCR Data across every lifecycle
    // generation. Cancellation does not release bytes until the deferred job
    // drops its Data or the async operation actually returns.
    var pendingOCRJobsByGeneration: [UInt64: Int] = [:]
    var pendingOCRBytesByGeneration: [UInt64: Int] = [:]
    let maxPendingOCRJobs = MacClippyOCRSchedulePolicy.maxPendingJobs
    // OCR is enrichment work. Bound retained source images by bytes as well
    // as operation count so a burst of large screenshots cannot keep close to
    // a gigabyte of Data alive while Vision waits for a worker.
    let maxPendingOCRBytes = MacClippyOCRSchedulePolicy.maxPendingBytes
    var deferredOCRJobs: [MacClippyDeferredOCRJob] = []
    var ocrScheduleTimer: DispatchSourceTimer?
    var ocrPowerObserver: NSObjectProtocol?
    var capturePauseTimer: DispatchSourceTimer?
    var ocrScheduleConditionsProvider: @Sendable () -> (
        secondsSinceLastInput: TimeInterval,
        isLowPowerMode: Bool
    ) = {
        (
            MacClippyUserInputIdle.secondsSinceLastInput(),
            ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }
    var retentionTimer: DispatchSourceTimer?
    // UserDefaults.didChangeNotification does not identify the changed key.
    // Keep the comparison on captureQueue and coalesce only actual retention
    // preference changes, so typing an exclusion regex never schedules a full
    // storage sweep for every keystroke.
    var retentionPreferencesSnapshot: MacClippyRetentionPreferencesSnapshot?
    var retentionDebounceWorkItem: DispatchWorkItem?
    var defaultsObserver: NSObjectProtocol?
    let usesRuntimeExclusionRules: Bool
    let snippetExpansionEnabled: Bool
    let storageDegradedReasons = MacClippyStorageDegradedReasons()
    let recognizeOCR: @Sendable (Data) async throws -> String
    let recognizeOCRLayout: @Sendable (CGImage) async throws -> MacClippyOCRResult
    #if DEBUG
        var failNextOCRSearchUpsertForTesting = false
        var beforeCaptureTransactionForTesting: (@Sendable () -> Void)?
        var afterSelectionSearchBatchForTesting: (@Sendable (Int) -> Void)?
    #endif

    // `start`, `stop`, and permission-driven snippet changes touch AppKit
    // lifecycle resources outside `storeLock`. Keep their transition atomic
    // with respect to one another even when a caller tears down the runtime
    // from a different queue during shutdown.
    // `lifecycleLock` serializes AppKit-facing start/stop transitions. The
    // state lock is intentionally separate from `storeLock`: cancellation
    // checkpoints may run while a storage operation is in progress and must
    // never deadlock with stop().
    let lifecycleLock = NSLock()
    // A lifecycle-aware storage operation holds this gate across its token
    // check and commit. Invalidation takes the same gate, so stop() cannot
    // slip between the check and a database write. This is deliberately
    // separate from storeLock: ordinary UI reads/writes do not need to delay
    // lifecycle invalidation unless a lifecycle-bound commit is already in
    // progress.
    let lifecycleCommitLock = NSLock()
    let lifecycleStateLock = NSLock()
    var running = false
    var lifecycleGeneration: UInt64 = 0

    var isRunning: Bool {
        withLifecycleStateLock { running }
    }

    init(
        paths: MacClippyPaths? = nil,
        keychain: MacClippyKeychainBackend? = nil,
        observer: PasteboardObserver? = nil,
        pasteInjector: MacClippyPasteInjector? = nil,
        pasteboardWriteSentinel: MacClippyPasteboardWriteSentinel? = nil,
        managesInjectedObserverPreferences: Bool = false,
        retentionPolicyOverride: RetentionPolicy? = nil,
        enableSnippetExpansion: Bool = true,
        preferencesDefaults: UserDefaults = .standard,
        ocrRecognizer: @escaping @Sendable (Data) async throws -> String = { data in
            try await MacClippyOCRService().recognize(data: data)
        },
        ocrLayoutRecognizer: @escaping @Sendable (CGImage) async throws -> MacClippyOCRResult = { image in
            try await MacClippyOCRService().recognizeLayout(image: image)
        }
    ) throws {
        let storage = try MacClippyRuntimeStorage(paths: paths, keychain: keychain)
        let resolvedWriteSentinel = pasteboardWriteSentinel ?? MacClippyPasteboardWriteSentinel()
        writeSentinel = resolvedWriteSentinel
        self.paths = storage.paths
        databases = storage.databases
        clipboardStore = storage.clipboardStore
        searchStore = storage.searchStore
        pinboardStore = storage.pinboardStore
        snippetStore = storage.snippetStore
        snippetLookupSnapshot = storage.snippetLookupSnapshot
        blobStore = storage.blobStore
        thumbnailDiskCache = storage.thumbnailDiskCache
        self.retentionPolicyOverride = retentionPolicyOverride

        usesRuntimeExclusionRules = observer == nil || managesInjectedObserverPreferences
        snippetExpansionEnabled = enableSnippetExpansion
        self.preferencesDefaults = preferencesDefaults
        if let observer {
            self.observer = observer
        } else {
            self.observer = PasteboardObserver(
                exclusionRules: MacClippyRetentionPreferences.exclusionRules(from: preferencesDefaults),
                writeSentinel: resolvedWriteSentinel
            )
        }

        let injector = pasteInjector ?? MacClippyPasteInjector(writeSentinel: resolvedWriteSentinel)
        self.pasteInjector = injector
        recognizeOCR = ocrRecognizer
        recognizeOCRLayout = ocrLayoutRecognizer
        historyEntryCache.totalCostLimit = 64 * 1024 * 1024
        historyEntryCache.countLimit = 500
        let lookupSnapshot = snippetLookupSnapshot
        snippetExpander = MacClippySnippetExpander(
            lookup: { lookupSnapshot.body(for: $0) },
            injector: injector
        )
        captureQueue.setSpecific(key: captureQueueKey, value: ())
        maintenanceQueue.setSpecific(key: maintenanceQueueKey, value: ())
        captureQueueAdmission.setCapacityAvailableHandler { [weak self] in
            self?.requestCaptureQueueRecoveryIfPossible()
        }
        blobStore.setDeferredDeleteHandler { [weak self] blobID in
            self?.scheduleDeferredBlobDelete(blobID)
        }
    }

    deinit {
        stop()
        drainCaptureQueueForShutdown()
        drainMaintenanceQueueForShutdown()
        drainLifecycleCommitsForShutdown()
        databases.forEach { database in
            do {
                try database.queue.close()
            } catch {
                MacClippyLog.record(
                    category: .storage,
                    code: .databaseHealthFailed,
                    operation: "database_close",
                    recoveryAction: "retry_on_next_launch",
                    impact: "database_close_failed"
                )
            }
        }
    }

    func measureDiagnosticMetric<T>(
        _ operation: String,
        _ work: () throws -> T
    ) rethrows -> T {
        let signpostID = OSSignpostID(log: macClippyRuntimePerformanceLog)
        os_signpost(
            .begin,
            log: macClippyRuntimePerformanceLog,
            name: "runtime_operation",
            signpostID: signpostID,
            "%{public}s",
            operation
        )
        let startedAt = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
            let milliseconds = min(elapsed / 1_000_000, UInt64(Int.max))
            MacClippyDiagnosticsRecorder.shared.recordMetric(
                operation: operation,
                durationMilliseconds: Int(milliseconds)
            )
            os_signpost(
                .end,
                log: macClippyRuntimePerformanceLog,
                name: "runtime_operation",
                signpostID: signpostID
            )
        }
        return try work()
    }

    // Paste injection is the user-visible operation. Frequency is derived
    // metadata, so a database failure after the OS accepted the injected
    // paste must not turn a successful paste into a thrown/partial result.
    // Keep the failure observable and let the next maintenance/recovery path
    // handle the stale counter instead of silently swallowing it.
    func recordSuccessfulPasteFrequency(for id: RecordID) {
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

extension MacClippyCapturePayload {
    var imageData: Data? {
        if case let .image(data, _, _) = self { return data }
        return nil
    }
}
