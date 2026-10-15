import AppKit
import Foundation

import MacClippyCore

enum MacClippyPasteboardSnapshotReadPolicy {
    static let maxGenerationAttempts = 3
    static let maxProviderRetries = 16
    static let snapshotDeadline: TimeInterval = 0.2
}

extension MacClippySystemPasteboardReader {
    public func read() -> PasteboardChange {
        read(shouldContinue: { true })
    }

    public func read(shouldContinue: () -> Bool) -> PasteboardChange {
        switch readOutcome(shouldContinue: shouldContinue) {
        case let .success(change):
            return change
        case .failed, .cancelled, .generationUnavailable:
            return emptyChange(at: rememberedChangeCount())
        }
    }

    public func readOutcome(shouldContinue: () -> Bool) -> MacClippyPasteboardReadOutcome {
        accessCoordinator.withAccess {
            do {
                let outcome = try readPasteboardOutcome(shouldContinue: shouldContinue)
                if case let .success(change) = outcome {
                    rememberChangeCount(change.changeCount)
                }
                return outcome
            } catch {
                if let nativeError = error as? MacClippyObjectiveCException { onReadFailure(nativeError) }
                return .failed(MacClippyPasteboardReadFailure(error: error))
            }
        }
    }

    private func readPasteboardOutcome(shouldContinue: () -> Bool) throws -> MacClippyPasteboardReadOutcome {
        var budget = MacClippyPasteboardSnapshotReadBudget()

        for _ in 0..<MacClippyPasteboardSnapshotReadPolicy.maxGenerationAttempts {
            guard shouldContinue() else { return .cancelled }
            let sampledChangeCount = try MacClippyNativePasteboard.changeCount(of: pasteboard)
            let sampledSourceAppBundleID = sourceAppBundleID()
            guard shouldContinue() else { return .cancelled }
            guard try MacClippyNativePasteboard.changeCount(of: pasteboard) == sampledChangeCount else { continue }
            guard budget.isWithinDeadline else {
                return .failed(MacClippyPasteboardReadFailure(
                    operation: "pasteboard.snapshot",
                    message: "Snapshot deadline expired before a stable read."
                ))
            }

            var context = MacClippyPasteboardSnapshotReadContext(
                changeCount: sampledChangeCount,
                budget: budget
            )
            let change = try materialize(
                sourceAppBundleID: sampledSourceAppBundleID,
                context: &context,
                shouldContinue: shouldContinue
            )
            budget = context.budget
            if let change {
                return .success(change)
            }
            guard shouldContinue() else { return .cancelled }
            let currentChangeCount = try MacClippyNativePasteboard.changeCount(of: pasteboard)
            guard currentChangeCount == sampledChangeCount else {
                continue
            }
            return .failed(MacClippyPasteboardReadFailure(
                operation: "pasteboard.snapshot",
                message: "Snapshot could not be completed for the still-current generation."
            ))
        }

        return .failed(MacClippyPasteboardReadFailure(
            operation: "pasteboard.generation-stability",
            message: "Pasteboard changed during every bounded snapshot attempt."
        ))
    }

    public func read(changeCount: Int, shouldContinue: () -> Bool) -> PasteboardChange? {
        if case let .success(change) = readOutcome(changeCount: changeCount, shouldContinue: shouldContinue) {
            return change
        }
        return nil
    }

    public func readOutcome(
        changeCount: Int,
        shouldContinue: () -> Bool
    ) -> MacClippyPasteboardReadOutcome {
        accessCoordinator.withAccess {
            do {
                guard shouldContinue() else { return .cancelled }
                guard try MacClippyNativePasteboard.changeCount(of: pasteboard) == changeCount else {
                    return .generationUnavailable
                }
                let sampledSourceAppBundleID = sourceAppBundleID()
                guard shouldContinue() else { return .cancelled }
                guard try MacClippyNativePasteboard.changeCount(of: pasteboard) == changeCount else {
                    return .generationUnavailable
                }
                var context = MacClippyPasteboardSnapshotReadContext(changeCount: changeCount)
                let change = try materialize(
                    sourceAppBundleID: sampledSourceAppBundleID,
                    context: &context,
                    shouldContinue: shouldContinue
                )
                if let change {
                    rememberChangeCount(change.changeCount)
                    return .success(change)
                }
                guard shouldContinue() else { return .cancelled }
                guard try MacClippyNativePasteboard.changeCount(of: pasteboard) == changeCount else {
                    return .generationUnavailable
                }
                return .failed(MacClippyPasteboardReadFailure(
                    operation: "pasteboard.snapshot",
                    message: "Snapshot could not be completed for the requested current generation."
                ))
            } catch {
                if let nativeError = error as? MacClippyObjectiveCException { onReadFailure(nativeError) }
                return .failed(MacClippyPasteboardReadFailure(error: error))
            }
        }
    }

    // Re-reads only the previously-unavailable slots. The change count is
    // sampled before obtaining item references, and every provider call is
    // bracketed by generation and cancellation checks. If a provider changes
    // the pasteboard, the caller receives the original generation so its
    // post-read guard rejects this partial reread.
    public func reread(
        change: PasteboardChange,
        unavailableTypes: [(itemIndex: Int, uti: String)]
    ) -> PasteboardChange {
        reread(change: change, unavailableTypes: unavailableTypes, shouldContinue: { true })
    }

    public func reread(
        change: PasteboardChange,
        unavailableTypes: [(itemIndex: Int, uti: String)],
        shouldContinue: () -> Bool
    ) -> PasteboardChange {
        switch rereadOutcome(change: change, unavailableTypes: unavailableTypes, shouldContinue: shouldContinue) {
        case let .success(updated): return updated
        case .failed, .cancelled, .generationUnavailable: return change
        }
    }

    public func rereadOutcome(
        change: PasteboardChange,
        unavailableTypes: [(itemIndex: Int, uti: String)],
        shouldContinue: () -> Bool
    ) -> MacClippyPasteboardReadOutcome {
        accessCoordinator.withAccess {
            do {
                guard shouldContinue() else { return .cancelled }
                guard try MacClippyNativePasteboard.changeCount(of: pasteboard) == change.changeCount else {
                    return .generationUnavailable
                }
                let updated = try rereadPasteboard(
                    change: change,
                    unavailableTypes: unavailableTypes,
                    shouldContinue: shouldContinue
                )
                guard shouldContinue() else { return .cancelled }
                guard try MacClippyNativePasteboard.changeCount(of: pasteboard) == change.changeCount else {
                    return .generationUnavailable
                }
                rememberChangeCount(updated.changeCount)
                return .success(updated)
            } catch {
                if let nativeError = error as? MacClippyObjectiveCException { onReadFailure(nativeError) }
                return .failed(MacClippyPasteboardReadFailure(error: error))
            }
        }
    }

}
