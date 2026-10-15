import AppKit
import Foundation

enum SnapshotClearResult {
    case clipboardChanged
    case cleared(changeCount: Int)
    case failedWithoutMutation
    case clearedThenFailed(changeCount: Int)
    case ambiguousFailure
}

extension MacClippyPasteInjector {
    func prepare(
        _ content: MacClippyPasteboardContent,
        gate: MacClippyPasteInjectionGate?,
        sentinel: MacClippyPasteboardWriteSentinel?
    ) throws {
        try withOperationLock {
          try pasteboardAccessCoordinator.withAccess {
            guard gate?.isOpen != false else { throw MacClippyPasteboardPrepareError.gateClosed }
            let original = snapshotPasteboard(pasteboard)
            guard original.isComplete else {
                throw MacClippyPasteboardPrepareError.incompleteSnapshot
            }
            guard let prepared = preparedSnapshot(for: content) else {
                throw MacClippyPasteboardPrepareError.writeFailed
            }
            guard (try? MacClippyNativePasteboard.changeCount(of: pasteboard)) == original.changeCount else {
                throw MacClippyPasteboardPrepareError.writeFailed
            }

            let result = writeSnapshot(
                prepared,
                to: pasteboard,
                sentinel: sentinel,
                expectedChangeCount: original.changeCount,
                gate: gate
            )
            try finishPrepare(result, original: original, sentinel: sentinel, gate: gate)
          }
        }
    }

    func preparedSnapshot(for content: MacClippyPasteboardContent) -> PasteboardSnapshot? {
        let stagingBoard = NSPasteboard.withUniqueName()
        guard prepareContent(content, stagingBoard) else { return nil }
        let snapshot = snapshotPasteboard(stagingBoard)
        guard snapshot.isComplete else { return nil }
        return snapshot
    }

    func materializedSnapshot(of source: NSPasteboard) throws -> PasteboardSnapshot {
        MacClippyPasteboardAccessCoordinator.shared(for: source).withAccess {
            snapshotPasteboard(source)
        }
    }

    func snapshotPasteboard(_ source: NSPasteboard) -> PasteboardSnapshot {
        MacClippyPasteboardAccessCoordinator.shared(for: source).withAccess {
            snapshotPasteboardWithoutLock(source)
        }
    }

    func snapshotPasteboardWithoutLock(_ source: NSPasteboard) -> PasteboardSnapshot {
        guard let initialChangeCount = try? MacClippyNativePasteboard.changeCount(of: source) else {
            return PasteboardSnapshot(items: [], isComplete: false, changeCount: 0)
        }
        var isComplete = true
        guard let pasteboardItems = try? MacClippyNativePasteboard.items(of: source) else {
            return PasteboardSnapshot(items: [], isComplete: false, changeCount: initialChangeCount)
        }
        let items: [[(type: NSPasteboard.PasteboardType, data: Data)]] = pasteboardItems.map { item in
            guard let typeNames = try? MacClippyNativePasteboard.types(of: item) else {
                isComplete = false
                return []
            }
            return typeNames.compactMap { typeName -> (type: NSPasteboard.PasteboardType, data: Data)? in
                let type = NSPasteboard.PasteboardType(typeName)
                guard let data = try? MacClippyNativePasteboard.data(from: item, forType: type) else {
                    isComplete = false
                    return nil
                }
                return (type: type, data: data)
            }
        }
        return PasteboardSnapshot(
            items: items,
            isComplete: isComplete && (try? MacClippyNativePasteboard.changeCount(of: source)) == initialChangeCount,
            changeCount: initialChangeCount
        )
    }

    func writeSnapshot(
        _ snapshot: PasteboardSnapshot,
        to destination: NSPasteboard,
        sentinel: MacClippyPasteboardWriteSentinel?,
        expectedChangeCount: Int,
        gate: MacClippyPasteInjectionGate?
    ) -> SnapshotWriteResult {
        MacClippyPasteboardAccessCoordinator.shared(for: destination).withAccess {
            writeSnapshotWithoutLock(
                snapshot,
                to: destination,
                sentinel: sentinel,
                expectedChangeCount: expectedChangeCount,
                gate: gate
            )
        }
    }

    private func writeSnapshotWithoutLock(
        _ snapshot: PasteboardSnapshot,
        to destination: NSPasteboard,
        sentinel: MacClippyPasteboardWriteSentinel?,
        expectedChangeCount: Int,
        gate: MacClippyPasteInjectionGate?
    ) -> SnapshotWriteResult {
        guard (try? MacClippyNativePasteboard.changeCount(of: destination)) == expectedChangeCount else {
            return .clipboardChanged
        }
        guard gate?.isOpen != false else { return .cancelled(restoreIfChangeCountIs: nil) }
        guard let items = pasteboardItems(from: snapshot) else {
            return .failed(restoreIfChangeCountIs: nil)
        }
        let clearOutcome = clearSnapshotPasteboard(
            destination,
            expectedChangeCount: expectedChangeCount,
            sentinel: sentinel,
            gate: gate
        )
        guard case let .written(ownedChangeCount) = clearOutcome else { return clearOutcome }
        guard gate?.isOpen != false else {
            return .cancelled(restoreIfChangeCountIs: ownedChangeCount)
        }
        guard writePreparedItems(
            items,
            to: destination,
            sentinel: sentinel,
            sentinelCount: ownedChangeCount,
            gate: gate
        ) else {
            guard (try? MacClippyNativePasteboard.changeCount(of: destination)) == ownedChangeCount else {
                sentinel?.cancel(changeCount: ownedChangeCount)
                return .clipboardChanged
            }
            return gate?.isOpen == false
                ? .cancelled(restoreIfChangeCountIs: ownedChangeCount)
                : .failed(restoreIfChangeCountIs: ownedChangeCount)
        }
        guard (try? MacClippyNativePasteboard.changeCount(of: destination)) == ownedChangeCount else {
            sentinel?.cancel(changeCount: ownedChangeCount)
            return .clipboardChanged
        }
        guard gate?.isOpen != false else {
            return .cancelled(restoreIfChangeCountIs: ownedChangeCount)
        }
        return .written(changeCount: ownedChangeCount)
    }

    private func clearSnapshotPasteboard(
        _ destination: NSPasteboard,
        expectedChangeCount: Int,
        sentinel: MacClippyPasteboardWriteSentinel?,
        gate: MacClippyPasteInjectionGate?
    ) -> SnapshotWriteResult {
        let expectedClearedChangeCount = expectedChangeCount + 1
        sentinel?.beginWrite(expectedChangeCount: expectedClearedChangeCount)
        guard let clearResult = performGated(gate, {
            clearDestination(
                destination,
                expectedChangeCount: expectedChangeCount,
                expectedClearedChangeCount: expectedClearedChangeCount
            )
        }) else {
            sentinel?.cancel(changeCount: expectedClearedChangeCount)
            return .cancelled(restoreIfChangeCountIs: nil)
        }
        guard case let .cleared(ownedChangeCount) = clearResult else {
            sentinel?.cancel(changeCount: expectedClearedChangeCount)
            return writeResult(for: clearResult)
        }
        guard ownedChangeCount == expectedClearedChangeCount else {
            sentinel?.cancel(changeCount: expectedClearedChangeCount)
            return .clipboardChanged
        }
        guard let observedChangeCount = try? MacClippyNativePasteboard.changeCount(of: destination) else {
            sentinel?.cancel(changeCount: expectedClearedChangeCount)
            return .restoreFailed
        }
        guard observedChangeCount == ownedChangeCount else {
            sentinel?.cancel(changeCount: expectedClearedChangeCount)
            return observedChangeCount > ownedChangeCount ? .clipboardChanged : .restoreFailed
        }
        return .written(changeCount: ownedChangeCount)
    }

    private func clearDestination(
        _ destination: NSPasteboard,
        expectedChangeCount: Int,
        expectedClearedChangeCount: Int
    ) -> SnapshotClearResult {
        guard (try? MacClippyNativePasteboard.changeCount(of: destination)) == expectedChangeCount else {
            return .clipboardChanged
        }
        do {
            try MacClippyNativePasteboard.clear(destination)
        } catch let exception as MacClippyObjectiveCException {
            return classifyClearException(
                exception,
                destination: destination,
                expectedChangeCount: expectedChangeCount,
                expectedClearedChangeCount: expectedClearedChangeCount
            )
        } catch {
            let changeCount = try? MacClippyNativePasteboard.changeCount(of: destination)
            return changeCount == expectedChangeCount ? .failedWithoutMutation : .ambiguousFailure
        }
        guard let changeCount = try? MacClippyNativePasteboard.changeCount(of: destination) else {
            return .ambiguousFailure
        }
        return .cleared(changeCount: changeCount)
    }

    private func writePreparedItems(
        _ items: [NSPasteboardItem],
        to destination: NSPasteboard,
        sentinel: MacClippyPasteboardWriteSentinel?,
        sentinelCount: Int,
        gate: MacClippyPasteInjectionGate?
    ) -> Bool {
        guard !items.isEmpty else { return true }
        guard let didWrite = performGated(gate, { writeObjects(destination, items) }) else {
            sentinel?.cancel(changeCount: sentinelCount)
            return false
        }
        guard (try? MacClippyNativePasteboard.changeCount(of: destination)) == sentinelCount else {
            sentinel?.cancel(changeCount: sentinelCount)
            return false
        }
        guard didWrite else {
            sentinel?.cancel(changeCount: sentinelCount)
            return false
        }
        return true
    }

    func rollback(
        _ snapshot: PasteboardSnapshot,
        expectedChangeCount: Int
    ) -> Bool {
        pasteboardAccessCoordinator.withAccess {
            guard (try? MacClippyNativePasteboard.changeCount(of: pasteboard)) == expectedChangeCount else {
                return false
            }
            return restore(snapshot, onlyIfChangeCountIs: expectedChangeCount).isRestored
        }
    }

    private func pasteboardItems(from snapshot: PasteboardSnapshot) -> [NSPasteboardItem]? {
        var items: [NSPasteboardItem] = []
        items.reserveCapacity(snapshot.items.count)
        for values in snapshot.items {
            let item = NSPasteboardItem()
            for value in values {
                guard (try? MacClippyNativePasteboard.set(value.data, on: item, forType: value.type)) == true else {
                    return nil
                }
            }
            items.append(item)
        }
        return items
    }

    /// Restores a snapshot only while the pasteboard is still at the expected
    /// generation. The retry reuses the cleared generation.
    enum RestoreOutcome: Equatable {
        case restored(changeCount: Int)
        case ownershipLost
        case writeFailed
        case ambiguousFailure
    }

    func restore(
        _ snapshot: PasteboardSnapshot,
        onlyIfChangeCountIs expectedCount: Int
    ) -> RestoreOutcome {
        pasteboardAccessCoordinator.withAccess {
            restoreWithoutLock(snapshot, onlyIfChangeCountIs: expectedCount)
        }
    }

    private func restoreWithoutLock(
        _ snapshot: PasteboardSnapshot,
        onlyIfChangeCountIs expectedCount: Int
    ) -> RestoreOutcome {
        guard (try? MacClippyNativePasteboard.changeCount(of: pasteboard)) == expectedCount else {
            return .ownershipLost
        }
        guard let items = pasteboardItems(from: snapshot) else { return .writeFailed }
        let nextChangeCount = expectedCount + 1
        writeSentinel?.beginWrite(expectedChangeCount: nextChangeCount)
        if let clearFailure = clearPasteboardForRestore(
            expectedCount: expectedCount,
            nextChangeCount: nextChangeCount
        ) {
            return clearFailure
        }
        guard !items.isEmpty else {
            writeSentinel?.cancel(changeCount: expectedCount)
            return .restored(changeCount: nextChangeCount)
        }
        return writeRestoredItems(items, expectedCount: expectedCount, nextChangeCount: nextChangeCount)
    }

    private func clearPasteboardForRestore(
        expectedCount: Int,
        nextChangeCount: Int
    ) -> RestoreOutcome? {
        do {
            try MacClippyNativePasteboard.clear(pasteboard)
        } catch let exception as MacClippyObjectiveCException {
            guard exception.nativeOperationCompleted else {
                writeSentinel?.cancel(changeCount: nextChangeCount)
                return .ambiguousFailure
            }
            guard let observedCount = try? MacClippyNativePasteboard.changeCount(of: pasteboard) else {
                writeSentinel?.cancel(changeCount: nextChangeCount)
                return .writeFailed
            }
            guard observedCount == nextChangeCount else {
                writeSentinel?.cancel(changeCount: nextChangeCount)
                return observedCount > nextChangeCount ? .ownershipLost : .writeFailed
            }
            guard snapshotIsEmpty(pasteboard, changeCount: nextChangeCount) else {
                writeSentinel?.cancel(changeCount: nextChangeCount)
                return .writeFailed
            }
        } catch {
            writeSentinel?.cancel(changeCount: nextChangeCount)
            return .writeFailed
        }
        guard let observedCount = try? MacClippyNativePasteboard.changeCount(of: pasteboard) else {
            writeSentinel?.cancel(changeCount: nextChangeCount)
            return .writeFailed
        }
        guard observedCount == nextChangeCount else {
            writeSentinel?.cancel(changeCount: nextChangeCount)
            return observedCount > nextChangeCount ? .ownershipLost : .writeFailed
        }
        return nil
    }

    private func writeRestoredItems(
        _ items: [NSPasteboardItem],
        expectedCount: Int,
        nextChangeCount: Int
    ) -> RestoreOutcome {
        for _ in 0..<2 {
            let didWrite = writeObjects(pasteboard, items)
            guard let observedChangeCount = try? MacClippyNativePasteboard.changeCount(of: pasteboard) else {
                writeSentinel?.cancel(changeCount: nextChangeCount)
                return .writeFailed
            }
            guard observedChangeCount == nextChangeCount else {
                writeSentinel?.cancel(changeCount: nextChangeCount)
                return .ownershipLost
            }
            if didWrite {
                writeSentinel?.cancel(changeCount: expectedCount)
                return .restored(changeCount: nextChangeCount)
            }
        }
        writeSentinel?.cancel(changeCount: nextChangeCount)
        return .writeFailed
    }
}

extension MacClippyPasteInjector.RestoreOutcome {
    var isRestored: Bool {
        if case .restored = self { return true }
        return false
    }
}
