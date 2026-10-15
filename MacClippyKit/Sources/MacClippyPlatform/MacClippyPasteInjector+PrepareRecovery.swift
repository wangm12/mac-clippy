import AppKit
import Foundation

extension MacClippyPasteInjector {
    func finishPrepare(
        _ result: SnapshotWriteResult,
        original: PasteboardSnapshot,
        sentinel: MacClippyPasteboardWriteSentinel?,
        gate: MacClippyPasteInjectionGate?
    ) throws {
        switch result {
        case let .written(changeCount):
            guard gate?.isOpen != false else {
                try restoreAfterPrepareCancellation(original, expectedCount: changeCount, sentinel: sentinel)
                throw MacClippyPasteboardPrepareError.gateClosed
            }
        case let .failed(expectedCount):
            try restoreAfterPrepareFailure(original, expectedCount: expectedCount, sentinel: sentinel)
            throw MacClippyPasteboardPrepareError.writeFailed
        case let .cancelled(expectedCount):
            try restoreAfterPrepareCancellation(original, expectedCount: expectedCount, sentinel: sentinel)
            throw MacClippyPasteboardPrepareError.gateClosed
        case .clipboardChanged:
            throw MacClippyPasteboardPrepareError.writeFailed
        case .restoreFailed:
            throw MacClippyPasteboardPrepareError.restoreFailed
        }
    }

    private func restoreAfterPrepareFailure(
        _ original: PasteboardSnapshot,
        expectedCount: Int?,
        sentinel: MacClippyPasteboardWriteSentinel?
    ) throws {
        guard let expectedCount else { return }
        guard pasteboardAccessCoordinator.withAccess({
            (try? MacClippyNativePasteboard.changeCount(of: pasteboard)) == expectedCount
        }) else {
            sentinel?.cancel(changeCount: expectedCount)
            throw MacClippyPasteboardPrepareError.restoreFailed
        }
        guard restore(original, onlyIfChangeCountIs: expectedCount).isRestored else {
            sentinel?.cancel(changeCount: expectedCount)
            throw MacClippyPasteboardPrepareError.restoreFailed
        }
    }

    private func restoreAfterPrepareCancellation(
        _ original: PasteboardSnapshot,
        expectedCount: Int? = nil,
        sentinel: MacClippyPasteboardWriteSentinel?
    ) throws {
        guard let expectedCount else { return }
        guard pasteboardAccessCoordinator.withAccess({
            (try? MacClippyNativePasteboard.changeCount(of: pasteboard)) == expectedCount
        }) else {
            sentinel?.cancel(changeCount: expectedCount)
            throw MacClippyPasteboardPrepareError.restoreFailed
        }
        guard restore(original, onlyIfChangeCountIs: expectedCount).isRestored else {
            sentinel?.cancel(changeCount: expectedCount)
            throw MacClippyPasteboardPrepareError.restoreFailed
        }
    }
}
