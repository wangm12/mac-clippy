import Foundation

import MacClippyCore
import MacClippyPlatform

struct MacClippyCaptureQueueMetrics: Codable, Sendable, Equatable {
    let outstandingJobs: Int
    let estimatedRetainedBytes: Int
    let maximumOutstandingJobs: Int
    let maximumEstimatedRetainedBytes: Int
    let droppedChangeCount: Int
    let recoveredChangeCount: Int
    // Lifetime total of overload-dropped generations plus admitted jobs that
    // did not commit. It is intentionally monotonic even if a dropped current
    // generation is later recovered; the separate recovered counter records
    // that recovery.
    let notSavedCount: Int
    let persistFailureCount: Int
    let overloadErrorCount: Int
    let currentGenerationReadRequestCount: Int
    let hasUnrecoveredClipboardChanges: Bool

    static let empty = MacClippyCaptureQueueMetrics(
        outstandingJobs: 0,
        estimatedRetainedBytes: 0,
        maximumOutstandingJobs: MacClippyCaptureQueueAdmission.maximumOutstandingJobs,
        maximumEstimatedRetainedBytes: MacClippyCaptureQueueAdmission.maximumEstimatedRetainedBytes,
        droppedChangeCount: 0,
        recoveredChangeCount: 0,
        notSavedCount: 0,
        persistFailureCount: 0,
        overloadErrorCount: 0,
        currentGenerationReadRequestCount: 0,
        hasUnrecoveredClipboardChanges: false
    )
}

/// Bounds payloads waiting for or currently being persisted by the capture
/// queue. The estimate charges raw representation bytes plus a conservative
/// allowance for a mapped primary payload, searchable text, and metadata.
/// OCR has its own independent 8-job/64 MiB reservation after persistence.
final class MacClippyCaptureQueueAdmission: @unchecked Sendable {
    static let maximumOutstandingJobs = 8
    static let maximumEstimatedRetainedBytes = 256 * 1_024 * 1_024
    private static let maximumRememberedGenerations = 256

    private struct Reservation {
        let byteCount: Int
        let isRecovery: Bool
    }

    private struct RecoveryCandidate {
        let changeCount: Int
        let byteCount: Int
    }

    private let lock = NSLock()
    private var reservations: [UUID: Reservation] = [:]
    private var outstandingJobs = 0
    private var estimatedRetainedBytes = 0
    private var droppedChangeCount = 0
    private var recoveredChangeCount = 0
    private var notSavedCount = 0
    private var persistFailureCount = 0
    private var overloadErrorCount = 0
    private var currentGenerationReadRequestCount = 0
    private var rememberedDroppedGenerationOrder: [Int] = []
    private var rememberedDroppedGenerations: Set<Int> = []
    private var recoveryCandidate: RecoveryCandidate?
    private var recoveryReadRequested = false
    private var recoveryReadAdmissionObserved = false
    private var capacityAvailableHandler: (@Sendable () -> Void)?

    func setCapacityAvailableHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        capacityAvailableHandler = handler
        lock.unlock()
    }

    func admission(for change: PasteboardChange) -> MacClippyPasteboardCaptureAdmission? {
        let byteCount = Self.estimatedRetainedBytes(for: change)
        let recoveryAttemptWasPending: Bool
        lock.lock()
        recoveryAttemptWasPending = recoveryReadRequested
        if recoveryAttemptWasPending {
            recoveryReadAdmissionObserved = true
        }
        if let candidate = recoveryCandidate, change.changeCount > candidate.changeCount {
            // Once the system pasteboard has advanced, its earlier generation
            // cannot be re-read. Keep only the current generation eligible for
            // a later capacity recovery.
            recoveryCandidate = nil
        }

        guard byteCount <= Self.maximumEstimatedRetainedBytes,
              outstandingJobs < Self.maximumOutstandingJobs,
              estimatedRetainedBytes <= Self.maximumEstimatedRetainedBytes - byteCount else {
            let shouldRecordDrop = rememberDroppedGenerationLocked(change.changeCount)
            if recoveryCandidate.map({ change.changeCount >= $0.changeCount }) ?? true {
                recoveryCandidate = RecoveryCandidate(changeCount: change.changeCount, byteCount: byteCount)
            }
            lock.unlock()
            if shouldRecordDrop {
                MacClippyLog.notice(
                    category: .capture,
                    code: .captureQueueOverloaded,
                    operation: "capture_queue_admission",
                    recoveryAction: "read_current_clipboard_when_capacity_returns",
                    impact: "clipboard_change_not_saved; intermediate_generations_unrecoverable"
                )
            }
            return nil
        }

        let isRecovery = recoveryCandidate?.changeCount == change.changeCount
        let reservationID = UUID()
        reservations[reservationID] = Reservation(
            byteCount: byteCount,
            isRecovery: isRecovery
        )
        outstandingJobs += 1
        estimatedRetainedBytes += byteCount
        if isRecovery {
            recoveryCandidate = nil
        }
        recoveryReadRequested = false
        recoveryReadAdmissionObserved = false
        lock.unlock()

        return MacClippyPasteboardCaptureAdmission { [weak self] wasPersisted in
            self?.finish(reservationID: reservationID, wasPersisted: wasPersisted)
        }
    }

    /// Returns true once when capacity is available for the most recent
    /// dropped generation. The caller requests a fresh observer read; this
    /// object never retains or replays the dropped PasteboardChange.
    func beginCurrentGenerationReadIfPossible() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !recoveryReadRequested,
              let candidate = recoveryCandidate,
              candidate.byteCount <= Self.maximumEstimatedRetainedBytes,
              outstandingJobs < Self.maximumOutstandingJobs,
              estimatedRetainedBytes <= Self.maximumEstimatedRetainedBytes - candidate.byteCount else {
            return false
        }
        recoveryReadRequested = true
        recoveryReadAdmissionObserved = false
        currentGenerationReadRequestCount = currentGenerationReadRequestCount == Int.max
            ? Int.max
            : currentGenerationReadRequestCount + 1
        return true
    }

    func currentGenerationReadCompleted(changeCount: Int?) {
        lock.lock()
        defer { lock.unlock() }
        guard let changeCount else {
            recoveryReadRequested = false
            recoveryReadAdmissionObserved = false
            return
        }
        if let candidate = recoveryCandidate, candidate.changeCount < changeCount {
            // This completion has passed the candidate's generation. It can
            // no longer be read from NSPasteboard, so forget it. A completion
            // that reports an older poll-entry count must never erase a newer
            // candidate materialized during that same read.
            recoveryCandidate = nil
        } else if recoveryCandidate?.changeCount == changeCount,
                  recoveryReadRequested,
                  !recoveryReadAdmissionObserved {
            // The observer completed the read without passing a change to the
            // admission handler (for example an exclusion or own-write token).
            // That generation is not eligible for capture recovery.
            recoveryCandidate = nil
        }
        recoveryReadRequested = false
        recoveryReadAdmissionObserved = false
    }

    func recordPersistFailure() {
        lock.lock()
        persistFailureCount = Self.increment(persistFailureCount)
        lock.unlock()
    }

    func observerDidStop() {
        lock.lock()
        recoveryReadRequested = false
        recoveryReadAdmissionObserved = false
        lock.unlock()
    }

    var snapshot: MacClippyCaptureQueueMetrics {
        lock.lock()
        defer { lock.unlock() }
        return MacClippyCaptureQueueMetrics(
            outstandingJobs: outstandingJobs,
            estimatedRetainedBytes: estimatedRetainedBytes,
            maximumOutstandingJobs: Self.maximumOutstandingJobs,
            maximumEstimatedRetainedBytes: Self.maximumEstimatedRetainedBytes,
            droppedChangeCount: droppedChangeCount,
            recoveredChangeCount: recoveredChangeCount,
            notSavedCount: Self.saturatingAdd(droppedChangeCount, notSavedCount),
            persistFailureCount: persistFailureCount,
            overloadErrorCount: overloadErrorCount,
            currentGenerationReadRequestCount: currentGenerationReadRequestCount,
            hasUnrecoveredClipboardChanges: droppedChangeCount > recoveredChangeCount
        )
    }

    private func finish(reservationID: UUID, wasPersisted: Bool) {
        lock.lock()
        guard let reservation = reservations.removeValue(forKey: reservationID) else {
            lock.unlock()
            return
        }
        outstandingJobs = max(0, outstandingJobs - 1)
        estimatedRetainedBytes = max(0, estimatedRetainedBytes - reservation.byteCount)
        if !wasPersisted {
            notSavedCount = Self.increment(notSavedCount)
        }
        if reservation.isRecovery, wasPersisted {
            recoveredChangeCount = recoveredChangeCount == Int.max
                ? Int.max
                : recoveredChangeCount + 1
        }
        let handler = capacityAvailableHandler
        lock.unlock()
        handler?()
    }

    private func rememberDroppedGenerationLocked(_ changeCount: Int) -> Bool {
        guard !rememberedDroppedGenerations.contains(changeCount) else { return false }
        rememberedDroppedGenerations.insert(changeCount)
        rememberedDroppedGenerationOrder.append(changeCount)
        if rememberedDroppedGenerationOrder.count > Self.maximumRememberedGenerations {
            let evicted = rememberedDroppedGenerationOrder.removeFirst()
            rememberedDroppedGenerations.remove(evicted)
        }
        droppedChangeCount = droppedChangeCount == Int.max ? Int.max : droppedChangeCount + 1
        overloadErrorCount = Self.increment(overloadErrorCount)
        return true
    }

    private static func increment(_ value: Int) -> Int {
        value == Int.max ? Int.max : value + 1
    }

    private static func estimatedRetainedBytes(for change: PasteboardChange) -> Int {
        var rawBytes = 0
        var metadataBytes = 512
        for item in change.items {
            metadataBytes = saturatingAdd(metadataBytes, 1_024)
            for type in item.types {
                metadataBytes = saturatingAdd(
                    metadataBytes,
                    saturatingAdd(saturatingMultiply(type.utf8.count, by: 4), 128)
                )
            }
            for data in item.representations.values {
                rawBytes = saturatingAdd(rawBytes, data.count)
            }
        }

        // The mapper retains representation Data and can additionally create a
        // String/HTML search projection from one raw representation. Four raw
        // payload copies is intentionally conservative across UTF-8 storage,
        // attributed HTML conversion, and per-representation metadata arrays.
        let projectedBytes = saturatingMultiply(rawBytes, by: 4)
        return max(1, saturatingAdd(projectedBytes, metadataBytes))
    }

    private static func saturatingAdd(_ left: Int, _ right: Int) -> Int {
        guard right > 0 else { return max(0, left) }
        return left > Int.max - right ? Int.max : left + right
    }

    private static func saturatingMultiply(_ value: Int, by multiplier: Int) -> Int {
        guard value > 0 else { return 0 }
        return value > Int.max / multiplier ? Int.max : value * multiplier
    }
}

final class MacClippyRuntimeCaptureJob: @unchecked Sendable {
    private var change: PasteboardChange?
    private var projection: MacClippyCaptureProjection?
    private var admission: MacClippyPasteboardCaptureAdmission?

    init(
        change: PasteboardChange,
        projection: MacClippyCaptureProjection,
        admission: MacClippyPasteboardCaptureAdmission
    ) {
        self.change = change
        self.projection = projection
        self.admission = admission
    }

    func persist(_ operation: (PasteboardChange, MacClippyCaptureProjection) -> Bool) -> Bool {
        guard let change, let projection else {
            clearPayload()
            return false
        }
        let persisted = operation(change, projection)
        clearPayload()
        return persisted
    }

    func finish(wasPersisted: Bool) {
        let admission = self.admission
        self.admission = nil
        admission?.finish(wasPersisted: wasPersisted)
    }

    func clearPayload() {
        change = nil
        projection = nil
    }
}
