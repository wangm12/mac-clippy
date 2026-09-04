import Foundation

public enum MacClippyTimedPauseDuration: Int, CaseIterable, Sendable, Equatable {
    case thirtySeconds = 30
    case fiveMinutes = 300
    case oneHour = 3_600
    case untilResumed = 0

    public var seconds: TimeInterval? {
        self == .untilResumed ? nil : TimeInterval(rawValue)
    }

    public var title: String {
        switch self {
        case .thirtySeconds: "30 seconds"
        case .fiveMinutes: "5 minutes"
        case .oneHour: "1 hour"
        case .untilResumed: "Until I resume"
        }
    }
}

public struct MacClippyIgnoreNextCopyDecision: Equatable, Sendable {
    public let shouldIgnore: Bool
    public let remaining: Int
}

public enum MacClippyCapturePausePolicy {
    public static func endDate(
        now: Date,
        duration: MacClippyTimedPauseDuration
    ) -> Date {
        guard let seconds = duration.seconds else { return .distantFuture }
        return now.addingTimeInterval(seconds)
    }

    public static func isActive(now: Date, until: Date?) -> Bool {
        guard let until else { return false }
        return now < until
    }

    public static func consumeIgnoreNext(_ remaining: Int) -> MacClippyIgnoreNextCopyDecision {
        guard remaining > 0 else {
            return MacClippyIgnoreNextCopyDecision(shouldIgnore: false, remaining: 0)
        }
        return MacClippyIgnoreNextCopyDecision(shouldIgnore: true, remaining: remaining - 1)
    }
}
