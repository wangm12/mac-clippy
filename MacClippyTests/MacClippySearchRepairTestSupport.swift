import Foundation

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippySearchRepairGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasBlocked = false
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    func blockFirstPass() {
        lock.lock()
        let shouldBlock = !hasBlocked
        hasBlocked = true
        lock.unlock()
        guard shouldBlock else { return }
        entered.signal()
        _ = resume.wait(timeout: .now() + 30)
    }
}

final class MacClippySearchRepairResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<MacClippySearchRepairReport, Error>?

    func store(_ result: Result<MacClippySearchRepairReport, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var result: Result<MacClippySearchRepairReport, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class MacClippySearchRepairMutationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: String?
    private var didClaim = false
    private var didCheckPendingBoundary = false
    private var pendingBoundaryPassed = false
    private var heavyIndexedAtFirstCommit = 0
    private var pageCommitCount = 0

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didClaim else { return false }
        didClaim = true
        return true
    }

    func record(_ error: Error) {
        lock.lock()
        storedError = String(describing: error)
        lock.unlock()
    }

    func recordPageCommit() {
        lock.lock()
        pageCommitCount += 1
        lock.unlock()
    }

    func claimPendingBoundaryCheck() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didCheckPendingBoundary else { return false }
        didCheckPendingBoundary = true
        return true
    }

    func recordPendingBoundary(passed: Bool, heavyIndexedCount: Int) {
        lock.lock()
        pendingBoundaryPassed = passed
        heavyIndexedAtFirstCommit = heavyIndexedCount
        lock.unlock()
    }

    var errorDescription: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    var didKeepPendingIDsOutOfFirstPage: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingBoundaryPassed
    }

    var firstPageHeavyRecordCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return heavyIndexedAtFirstCommit
    }

    var committedPageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pageCommitCount
    }
}

struct MacClippySearchRepairRuntimeFixture {
    let rootURL: URL
    let environment: MacClippyAppTestPasteboardEnvironment
    let runtime: MacClippyRuntime
}

struct MacClippySearchRepairMutationOperations {
    let editStarted: DispatchSemaphore
    let editFinished: DispatchSemaphore
    let deleteStarted: DispatchSemaphore
    let deleteFinished: DispatchSemaphore
}

struct SearchRepairPendingScenario {
    let labeled: ClipboardItemMeta
    let deleted: ClipboardItemMeta
    let heavyIDs: [RecordID]
    let mutationResult: MacClippySearchRepairMutationResult
}

final class MacClippySearchRepairBarrierBox: @unchecked Sendable {
    private let lock = NSLock()
    private var barrier: MacClippyMaintenanceIOCoordinator.RestoreBarrier?

    func store(_ barrier: MacClippyMaintenanceIOCoordinator.RestoreBarrier) {
        lock.lock()
        self.barrier = barrier
        lock.unlock()
    }

    func release() {
        lock.lock()
        barrier = nil
        lock.unlock()
    }
}
