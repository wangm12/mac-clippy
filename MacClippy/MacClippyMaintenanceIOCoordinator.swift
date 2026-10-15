import Foundation

/// Tracks maintenance work that performs file I/O outside the Runtime store
/// lock. Restore waits for backup readers, bounded search-repair work, and
/// active blob I/O, but not for an image decode/encode phase after its source
/// bytes have been read.
final class MacClippyMaintenanceIOCoordinator: @unchecked Sendable {
    static let shared = MacClippyMaintenanceIOCoordinator()

    enum OperationKind: Hashable {
        case backup
        case compression
        case searchRepair
    }

    fileprivate final class CancellationFlag {
        private let lock = NSLock()
        private var value = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func cancel() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    private struct OperationState {
        let kind: OperationKind
        let flag: CancellationFlag
    }

    private struct RootState {
        var operations: [UUID: OperationState] = [:]
        var activeCriticalIOCount = 0
        var restoreInProgress = false
    }

    final class Operation: @unchecked Sendable {
        private let coordinator: MacClippyMaintenanceIOCoordinator
        private let rootKey: String
        private let id: UUID
        private let flag: CancellationFlag

        fileprivate init(
            coordinator: MacClippyMaintenanceIOCoordinator,
            rootKey: String,
            id: UUID,
            flag: CancellationFlag
        ) {
            self.coordinator = coordinator
            self.rootKey = rootKey
            self.id = id
            self.flag = flag
        }

        var isCancelled: Bool { flag.isCancelled }

        func beginCriticalIO() -> CriticalIO? {
            coordinator.beginCriticalIO(for: self, rootKey: rootKey, id: id)
        }

        func finish() {
            coordinator.finishOperation(rootKey: rootKey, id: id)
        }

        fileprivate var cancellationFlag: CancellationFlag { flag }
        deinit { finish() }
    }

    final class CriticalIO: @unchecked Sendable {
        private let coordinator: MacClippyMaintenanceIOCoordinator
        private let rootKey: String
        private let lock = NSLock()
        private var isReleased = false

        fileprivate init(coordinator: MacClippyMaintenanceIOCoordinator, rootKey: String) {
            self.coordinator = coordinator
            self.rootKey = rootKey
        }

        func release() {
            lock.lock()
            guard !isReleased else {
                lock.unlock()
                return
            }
            isReleased = true
            lock.unlock()
            coordinator.finishCriticalIO(rootKey: rootKey)
        }

        deinit { release() }
    }

    final class RestoreBarrier: @unchecked Sendable {
        private let coordinator: MacClippyMaintenanceIOCoordinator
        private let rootKey: String

        fileprivate init(coordinator: MacClippyMaintenanceIOCoordinator, rootKey: String) {
            self.coordinator = coordinator
            self.rootKey = rootKey
        }

        deinit { coordinator.finishRestore(rootKey: rootKey) }
    }

    private let condition = NSCondition()
    private var roots: [String: RootState] = [:]

    private init() {}

    func beginOperation(at rootURL: URL, kind: OperationKind) -> Operation? {
        let rootKey = key(for: rootURL)
        condition.lock()
        defer { condition.unlock() }
        var state = roots[rootKey] ?? RootState()
        guard !state.restoreInProgress else { return nil }
        let id = UUID()
        let flag = CancellationFlag()
        state.operations[id] = OperationState(kind: kind, flag: flag)
        roots[rootKey] = state
        return Operation(coordinator: self, rootKey: rootKey, id: id, flag: flag)
    }

    func beginRestore(at rootURL: URL) -> RestoreBarrier {
        let rootKey = key(for: rootURL)
        condition.lock()
        while roots[rootKey]?.restoreInProgress == true {
            condition.wait()
        }
        var state = roots[rootKey] ?? RootState()
        state.restoreInProgress = true
        state.operations.values.forEach { $0.flag.cancel() }
        roots[rootKey] = state
        while hasRestoreBlockingOperation(in: state) || state.activeCriticalIOCount > 0 {
            condition.wait()
            state = roots[rootKey] ?? RootState(restoreInProgress: true)
        }
        condition.unlock()
        return RestoreBarrier(coordinator: self, rootKey: rootKey)
    }

    func cancelOperations(at rootURL: URL) {
        let rootKey = key(for: rootURL)
        condition.lock()
        roots[rootKey]?.operations.values.forEach { $0.flag.cancel() }
        condition.unlock()
    }

    private func beginCriticalIO(
        for operation: Operation,
        rootKey: String,
        id: UUID
    ) -> CriticalIO? {
        condition.lock()
        defer { condition.unlock() }
        guard var state = roots[rootKey],
              !state.restoreInProgress,
              !operation.cancellationFlag.isCancelled,
              state.operations[id] != nil else {
            return nil
        }
        state.activeCriticalIOCount += 1
        roots[rootKey] = state
        return CriticalIO(coordinator: self, rootKey: rootKey)
    }

    private func finishOperation(rootKey: String, id: UUID) {
        condition.lock()
        roots[rootKey]?.operations.removeValue(forKey: id)
        condition.broadcast()
        condition.unlock()
    }

    private func finishCriticalIO(rootKey: String) {
        condition.lock()
        if var state = roots[rootKey] {
            state.activeCriticalIOCount = max(0, state.activeCriticalIOCount - 1)
            roots[rootKey] = state
        }
        condition.broadcast()
        condition.unlock()
    }

    private func finishRestore(rootKey: String) {
        condition.lock()
        var state = roots[rootKey] ?? RootState()
        state.restoreInProgress = false
        roots[rootKey] = state
        condition.broadcast()
        condition.unlock()
    }

    private func hasRestoreBlockingOperation(in state: RootState) -> Bool {
        state.operations.values.contains { $0.kind == .backup || $0.kind == .searchRepair }
    }

    private func key(for rootURL: URL) -> String {
        rootURL.standardizedFileURL.path
    }
}
