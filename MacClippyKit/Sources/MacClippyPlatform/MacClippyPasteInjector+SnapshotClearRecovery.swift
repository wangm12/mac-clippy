import AppKit
import Foundation

extension MacClippyPasteInjector {
    func classifyClearException(
        _ exception: MacClippyObjectiveCException,
        destination: NSPasteboard,
        expectedChangeCount: Int,
        expectedClearedChangeCount: Int
    ) -> SnapshotClearResult {
        guard exception.nativeOperationCompleted,
              let changeCount = try? MacClippyNativePasteboard.changeCount(of: destination) else {
            return .ambiguousFailure
        }
        switch changeCount {
        case expectedClearedChangeCount:
            return snapshotIsEmpty(destination, changeCount: expectedClearedChangeCount)
                ? .clearedThenFailed(changeCount: expectedClearedChangeCount)
                : .ambiguousFailure
        case expectedChangeCount:
            return .failedWithoutMutation
        case let newerCount where newerCount > expectedClearedChangeCount:
            return .clipboardChanged
        default:
            return .ambiguousFailure
        }
    }

    func snapshotIsEmpty(_ pasteboard: NSPasteboard, changeCount: Int) -> Bool {
        let snapshot = snapshotPasteboardWithoutLock(pasteboard)
        return snapshot.isComplete && snapshot.changeCount == changeCount && snapshot.items.isEmpty
    }

    func writeResult(for clearResult: SnapshotClearResult) -> SnapshotWriteResult {
        switch clearResult {
        case .failedWithoutMutation:
            .failed(restoreIfChangeCountIs: nil)
        case let .clearedThenFailed(changeCount):
            .failed(restoreIfChangeCountIs: changeCount)
        case .ambiguousFailure:
            .restoreFailed
        case .clipboardChanged:
            .clipboardChanged
        case .cleared:
            preconditionFailure("handled above")
        }
    }

}
