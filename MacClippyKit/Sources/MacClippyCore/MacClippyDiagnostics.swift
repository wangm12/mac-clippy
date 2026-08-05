import Foundation
import OSLog

public enum MacClippyLogCategory: String, Codable, Sendable, CaseIterable {
    case lifecycle
    case capture
    case storage
    case fts
    case blob
    case paste
    case hotkey
    case permission
    case ui
}

public enum MacClippyErrorCode: String, Codable, Sendable, CaseIterable {
    case startupFailed
    case capturePersistFailed
    case captureInputTooLarge
    case ftsIndexFailed
    case ftsRepairFailed
    case blobCleanupFailed
    case retentionFailed
    case reconciliationFailed
    case reconciliationCompleted
    case blobIntegrityFailed
    case ocrFailed
    case pasteFailed
    case pasteMetadataUpdateFailed
    case hotkeyRegistrationFailed
    case permissionUnavailable
    case databaseHealthFailed
    case backupFailed
    case recoveryFailed
    case launchAtLoginUpdateFailed
}

public struct MacClippyDiagnosticsEvent: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let category: MacClippyLogCategory
    public let code: MacClippyErrorCode
    public let operation: String
    public let durationMilliseconds: Int?
    public let retryCount: Int
    public let recoveryAction: String?
    public let impact: String?

    public init(
        timestamp: Date = Date(),
        category: MacClippyLogCategory,
        code: MacClippyErrorCode,
        operation: String,
        durationMilliseconds: Int? = nil,
        retryCount: Int = 0,
        recoveryAction: String? = nil,
        impact: String? = nil
    ) {
        self.timestamp = timestamp
        self.category = category
        self.code = code
        self.operation = operation
        self.durationMilliseconds = durationMilliseconds
        self.retryCount = max(0, retryCount)
        self.recoveryAction = recoveryAction
        self.impact = impact
    }
}

public struct MacClippyDiagnosticsMetric: Codable, Sendable, Equatable {
    public let count: Int
    public let totalDurationMilliseconds: Int64
    public let maxDurationMilliseconds: Int64
    public let averageDurationMilliseconds: Double

    public init(
        count: Int,
        totalDurationMilliseconds: Int64,
        maxDurationMilliseconds: Int64
    ) {
        self.count = max(0, count)
        self.totalDurationMilliseconds = max(0, totalDurationMilliseconds)
        self.maxDurationMilliseconds = max(0, maxDurationMilliseconds)
        self.averageDurationMilliseconds = count > 0
            ? Double(self.totalDurationMilliseconds) / Double(count)
            : 0
    }
}

// SAFETY: The bounded event buffer and bounded metric-key map are the only
// mutable state and every operation on them is protected by `lock`. Diagnostics
// is called from capture, storage, UI, and permission queues, so this
// synchronous recorder is the deliberate isolation boundary instead of an
// async actor API.
public final class MacClippyDiagnosticsRecorder: @unchecked Sendable {
    public static let shared = MacClippyDiagnosticsRecorder()

    private let lock = NSLock()
    private let capacity: Int
    private var events: [MacClippyDiagnosticsEvent] = []
    private struct MetricAccumulator {
        var count = 0
        var totalDurationMilliseconds: Int64 = 0
        var maxDurationMilliseconds: Int64 = 0
    }

    private var metrics: [String: MetricAccumulator] = [:]

    public init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    public func record(_ event: MacClippyDiagnosticsEvent) {
        lock.lock()
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
        lock.unlock()
    }

    public func recentEvents() -> [MacClippyDiagnosticsEvent] {
        lock.lock()
        let snapshot = events
        lock.unlock()
        return snapshot
    }

    public func recordMetric(operation: String, durationMilliseconds: Int) {
        let normalizedOperation = operation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOperation.isEmpty, normalizedOperation.count <= 64 else { return }

        let duration = Int64(max(0, durationMilliseconds))
        lock.lock()
        defer { lock.unlock() }
        guard metrics[normalizedOperation] != nil || metrics.count < capacity else { return }

        var accumulator = metrics[normalizedOperation, default: MetricAccumulator()]
        accumulator.count = accumulator.count == Int.max ? Int.max : accumulator.count + 1
        accumulator.totalDurationMilliseconds = accumulator.totalDurationMilliseconds > Int64.max - duration
            ? Int64.max
            : accumulator.totalDurationMilliseconds + duration
        accumulator.maxDurationMilliseconds = max(accumulator.maxDurationMilliseconds, duration)
        metrics[normalizedOperation] = accumulator
    }

    public func metricSnapshot() -> [String: MacClippyDiagnosticsMetric] {
        lock.lock()
        let snapshot = metrics.mapValues {
            MacClippyDiagnosticsMetric(
                count: $0.count,
                totalDurationMilliseconds: $0.totalDurationMilliseconds,
                maxDurationMilliseconds: $0.maxDurationMilliseconds
            )
        }
        lock.unlock()
        return snapshot
    }

    public func clear() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        metrics.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

public enum MacClippyLog {
    private static let logger = Logger(subsystem: "com.macallyouneed.macclippy", category: "runtime")

    public static func record(
        category: MacClippyLogCategory,
        code: MacClippyErrorCode,
        operation: String,
        durationMilliseconds: Int? = nil,
        retryCount: Int = 0,
        recoveryAction: String? = nil,
        impact: String? = nil
    ) {
        let event = MacClippyDiagnosticsEvent(
            category: category,
            code: code,
            operation: operation,
            durationMilliseconds: durationMilliseconds,
            retryCount: retryCount,
            recoveryAction: recoveryAction,
            impact: impact
        )
        MacClippyDiagnosticsRecorder.shared.record(event)
        let duration = durationMilliseconds.map(String.init) ?? "-"
        logger.error(
            "category=\(category.rawValue, privacy: .public) code=\(code.rawValue, privacy: .public) operation=\(operation, privacy: .public) duration_ms=\(duration, privacy: .public) retry_count=\(retryCount, privacy: .public)"
        )
    }
}
