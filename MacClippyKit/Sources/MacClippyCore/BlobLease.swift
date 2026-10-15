import Foundation

/// A process-local read lease that keeps encrypted blobs on disk while a
/// caller reads or snapshots them. Releasing the last lease schedules deferred
/// deletion but never removes a file by itself.
public final class MacClippyBlobLease: @unchecked Sendable {
    private let registry: MacClippyBlobLeaseRegistry
    private let leaseID: UUID
    private let lock = NSLock()
    private var isReleased = false

    init(registry: MacClippyBlobLeaseRegistry, leaseID: UUID) {
        self.registry = registry
        self.leaseID = leaseID
    }

    public func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        lock.unlock()
        registry.release(leaseID: leaseID)
    }

    deinit { release() }
}

final class MacClippyBlobLeaseRegistry: @unchecked Sendable {
    static let shared = MacClippyBlobLeaseRegistry()

    private struct RootState {
        var rootLeaseCount = 0
        var blobLeaseCounts: [String: Int] = [:]
        var pendingDeleteIDs = Set<String>()
        var activeWrites = Set<String>()
        var activeDeletes = Set<String>()
        var deferredDeleteHandler: (@Sendable (String) -> Void)?
    }

    private struct LeaseState {
        let rootKey: String
        let blobIDs: Set<String>?
    }

    private let condition = NSCondition()
    private var roots: [String: RootState] = [:]
    private var leases: [UUID: LeaseState] = [:]

    private init() {}

    func acquire(rootKey: String, blobIDs: Set<String>?) -> MacClippyBlobLease {
        condition.lock()
        while isMutationInProgress(rootKey: rootKey, blobIDs: blobIDs) {
            condition.wait()
        }
        let leaseID = UUID()
        leases[leaseID] = LeaseState(rootKey: rootKey, blobIDs: blobIDs)
        var state = roots[rootKey] ?? RootState()
        if let blobIDs {
            for blobID in blobIDs {
                state.blobLeaseCounts[blobID, default: 0] += 1
            }
        } else {
            state.rootLeaseCount += 1
        }
        roots[rootKey] = state
        condition.unlock()
        return MacClippyBlobLease(registry: self, leaseID: leaseID)
    }

    func setDeferredDeleteHandler(
        rootKey: String,
        handler: (@Sendable (String) -> Void)?
    ) {
        condition.lock()
        var state = roots[rootKey] ?? RootState()
        state.deferredDeleteHandler = handler
        let callbacks = drainEligibleCallbacks(state: &state)
        roots[rootKey] = state
        condition.unlock()
        callbacks.forEach { $0.handler($0.blobID) }
    }

    func deleteOrDefer(
        rootKey: String,
        blobID: String,
        delete: () throws -> Void
    ) throws {
        condition.lock()
        var state = roots[rootKey] ?? RootState()
        if state.rootLeaseCount > 0 || state.blobLeaseCounts[blobID, default: 0] > 0 {
            state.pendingDeleteIDs.insert(blobID)
            roots[rootKey] = state
            condition.unlock()
            return
        }
        if state.activeWrites.contains(blobID) {
            state.pendingDeleteIDs.insert(blobID)
            roots[rootKey] = state
            condition.unlock()
            return
        }
        guard !state.activeDeletes.contains(blobID) else {
            condition.unlock()
            return
        }
        state.activeDeletes.insert(blobID)
        roots[rootKey] = state
        condition.unlock()

        do {
            try delete()
        } catch {
            finishMutation(rootKey: rootKey, blobID: blobID)
            throw error
        }
        finishMutation(rootKey: rootKey, blobID: blobID)
    }

    func write(
        rootKey: String,
        blobID: String,
        targetExists: () -> Bool,
        write: () throws -> Void
    ) throws {
        let targetWasPresent = targetExists()
        condition.lock()
        while isMutationInProgress(rootKey: rootKey, blobIDs: [blobID]) {
            condition.wait()
        }
        var state = roots[rootKey] ?? RootState()
        let isBlobLeased = state.blobLeaseCounts[blobID, default: 0] > 0
        let rootLeaseProtectsExistingFile = state.rootLeaseCount > 0 && targetWasPresent
        guard !isBlobLeased && !rootLeaseProtectsExistingFile else {
            condition.unlock()
            throw MacClippyBlobError.activeReadLease
        }
        state.activeWrites.insert(blobID)
        roots[rootKey] = state
        condition.unlock()

        do {
            try write()
        } catch {
            finishMutation(rootKey: rootKey, blobID: blobID)
            throw error
        }
        finishMutation(rootKey: rootKey, blobID: blobID)
    }

    func release(leaseID: UUID) {
        condition.lock()
        guard let lease = leases.removeValue(forKey: leaseID),
              var state = roots[lease.rootKey] else {
            condition.unlock()
            return
        }
        if let blobIDs = lease.blobIDs {
            for blobID in blobIDs {
                let nextCount = max(0, state.blobLeaseCounts[blobID, default: 0] - 1)
                if nextCount == 0 {
                    state.blobLeaseCounts.removeValue(forKey: blobID)
                } else {
                    state.blobLeaseCounts[blobID] = nextCount
                }
            }
        } else {
            state.rootLeaseCount = max(0, state.rootLeaseCount - 1)
        }
        let callbacks = drainEligibleCallbacks(state: &state)
        roots[lease.rootKey] = state
        condition.broadcast()
        condition.unlock()
        callbacks.forEach { $0.handler($0.blobID) }
    }

    private func finishMutation(rootKey: String, blobID: String) {
        condition.lock()
        guard var state = roots[rootKey] else {
            condition.broadcast()
            condition.unlock()
            return
        }
        state.activeWrites.remove(blobID)
        state.activeDeletes.remove(blobID)
        let callbacks = drainEligibleCallbacks(state: &state)
        roots[rootKey] = state
        condition.broadcast()
        condition.unlock()
        callbacks.forEach { $0.handler($0.blobID) }
    }

    private func isMutationInProgress(rootKey: String, blobIDs: Set<String>?) -> Bool {
        let state = roots[rootKey]
        if let blobIDs {
            return blobIDs.contains { blobID in
                state?.activeWrites.contains(blobID) == true
                    || state?.activeDeletes.contains(blobID) == true
            }
        }
        // New immutable blobs may be written during a backup. An in-flight
        // delete must finish before a root snapshot begins.
        return !(state?.activeDeletes.isEmpty ?? true)
    }

    private func drainEligibleCallbacks(
        state: inout RootState
    ) -> [(handler: @Sendable (String) -> Void, blobID: String)] {
        guard let handler = state.deferredDeleteHandler,
              state.rootLeaseCount == 0 else {
            return []
        }
        let eligible = state.pendingDeleteIDs.filter { blobID in
            state.blobLeaseCounts[blobID, default: 0] == 0
                && !state.activeWrites.contains(blobID)
                && !state.activeDeletes.contains(blobID)
        }
        state.pendingDeleteIDs.subtract(eligible)
        return eligible.map { (handler: handler, blobID: $0) }
    }
}
