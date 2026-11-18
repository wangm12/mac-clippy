import Foundation

#if DEBUG
/// Deterministic gates for maintenance regression tests. Search-repair page
/// hooks intentionally bracket the bounded source-to-index consistency fence.
enum MacClippyMaintenanceIOTestHooks {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var imageReadCallback: (@Sendable () -> Void)?
        var backupSnapshotCallback: (@Sendable () -> Void)?
        var storageSnapshotCallback: (@Sendable () -> Void)?
        var beforeSearchRepairPageCommit: (@Sendable () -> Void)?
        var afterSearchRepairPageCommit: (@Sendable () -> Void)?
    }

    private static let state = State()

    static func setAfterImageRead(_ callback: (@Sendable () -> Void)?) {
        state.lock.lock()
        state.imageReadCallback = callback
        state.lock.unlock()
    }

    static func setAfterBackupSnapshots(_ callback: (@Sendable () -> Void)?) {
        state.lock.lock()
        state.backupSnapshotCallback = callback
        state.lock.unlock()
    }

    static func setAfterStorageSnapshot(_ callback: (@Sendable () -> Void)?) {
        state.lock.lock()
        state.storageSnapshotCallback = callback
        state.lock.unlock()
    }

    static func setBeforeSearchRepairPageCommit(_ callback: (@Sendable () -> Void)?) {
        state.lock.lock()
        state.beforeSearchRepairPageCommit = callback
        state.lock.unlock()
    }

    static func setAfterSearchRepairPageCommit(_ callback: (@Sendable () -> Void)?) {
        state.lock.lock()
        state.afterSearchRepairPageCommit = callback
        state.lock.unlock()
    }

    static func afterImageRead() {
        state.lock.lock()
        let callback = state.imageReadCallback
        state.lock.unlock()
        callback?()
    }

    static func afterBackupSnapshots() {
        state.lock.lock()
        let callback = state.backupSnapshotCallback
        state.lock.unlock()
        callback?()
    }

    static func afterStorageSnapshot() {
        state.lock.lock()
        let callback = state.storageSnapshotCallback
        state.lock.unlock()
        callback?()
    }

    static func beforeSearchRepairPageCommit() {
        state.lock.lock()
        let callback = state.beforeSearchRepairPageCommit
        state.lock.unlock()
        callback?()
    }

    static func afterSearchRepairPageCommit() {
        state.lock.lock()
        let callback = state.afterSearchRepairPageCommit
        state.lock.unlock()
        callback?()
    }
}
#else
enum MacClippyMaintenanceIOTestHooks {
    static func afterImageRead() {}
    static func afterBackupSnapshots() {}
    static func afterStorageSnapshot() {}
    static func beforeSearchRepairPageCommit() {}
    static func afterSearchRepairPageCommit() {}
}
#endif
