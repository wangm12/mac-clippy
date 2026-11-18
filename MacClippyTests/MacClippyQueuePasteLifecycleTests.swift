import AppKit
import Foundation
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

private final class MacClippyDeferredQueuePasteHops: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [@MainActor () -> Void] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return work.count
    }

    func enqueue(_ operation: @escaping @MainActor () -> Void) {
        lock.lock()
        work.append(operation)
        lock.unlock()
    }

    @MainActor
    func run(at index: Int) {
        lock.lock()
        let operation = work.remove(at: index)
        lock.unlock()
        operation()
    }

    @MainActor
    func runAll() {
        while count > 0 {
            run(at: 0)
        }
    }
}

private final class MacClippyQueuePasteEventPoster: @unchecked Sendable {
    let ownedProcessIdentifier = Int32(ProcessInfo.processInfo.processIdentifier)

    private let lock = NSLock()
    private var globalPostCountValue = 0
    private var targetedProcessIdentifiersValue: [Int32] = []

    var globalPostCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return globalPostCountValue
    }

    var targetedProcessIdentifiers: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return targetedProcessIdentifiersValue
    }

    func recordGlobalPost() {
        lock.lock()
        globalPostCountValue += 1
        lock.unlock()
    }

    func recordTargetedPost(to processIdentifier: Int32) {
        lock.lock()
        targetedProcessIdentifiersValue.append(processIdentifier)
        lock.unlock()
    }
}

final class MacClippyQueuePasteLifecycleTests: XCTestCase {
    private var tempRoot: URL!
    private var pasteboard: NSPasteboard!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var runtime: MacClippyRuntime!
    private var eventPoster: MacClippyQueuePasteEventPoster!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyQueuePasteLifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyQueuePasteLifecycle-\(UUID().uuidString)"))
        defaultsSuiteName = "MacClippyQueuePasteLifecycle-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        let eventPoster = MacClippyQueuePasteEventPoster()
        self.eventPoster = eventPoster

        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { [eventPoster] _, _ in
                eventPoster.recordGlobalPost()
            },
            postEventsToProcess: { [eventPoster] _, _, processIdentifier in
                eventPoster.recordTargetedPost(to: processIdentifier)
            }
        )
        runtime = try MacClippyRuntime(
            paths: MacClippyPaths(rootURL: tempRoot),
            keychain: MacClippyInMemoryKeychain(),
            pasteInjector: injector,
            preferencesDefaults: defaults
        )
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        pasteboard = nil
        eventPoster = nil
        if let defaultsSuiteName {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        defaults = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    @MainActor
    func testQueuePasteCallbacksFromPreviousSessionCannotPublishAfterReopen() throws {
        let model = MacClippyDockModel(runtime: runtime, defaults: defaults)
        try appendThreeRecords(to: runtime)
        loadHistory(for: model, count: 3)
        model.beginSession()
        selectFirstTwoItems(in: model)

        let oldSession = model.sessionGeneration
        let oldHops = MacClippyDeferredQueuePasteHops()
        var didClose = false
        startQueuePaste(on: model, hops: oldHops) { didClose = true }
        waitForScheduledQueuePasteHops(oldHops, count: 3)

        model.endSession()
        model.beginSession()
        XCTAssertNotEqual(model.sessionGeneration, oldSession)

        oldHops.runAll()

        XCTAssertNil(model.queuePasteProgress, "delayed old progress must not publish into a reopened session")
        XCTAssertNil(model.queuePasteCancellationToken, "a stale finish must not restore or clear session ownership")
        XCTAssertNil(model.actionFeedback, "a stale finish must not publish feedback")
        XCTAssertFalse(didClose, "a stale finish must not close the reopened dock")
        XCTAssertEqual(eventPoster.globalPostCount, 2, "queue injection must use the fake global poster")
        XCTAssertTrue(
            eventPoster.targetedProcessIdentifiers.allSatisfy { $0 == eventPoster.ownedProcessIdentifier },
            "any targeted fake post must stay scoped to this test process"
        )
    }

    @MainActor
    func testStaleQueueFinishAndProgressCannotClearNewQueueOwnership() throws {
        let model = MacClippyDockModel(runtime: runtime, defaults: defaults)
        try appendThreeRecords(to: runtime)
        loadHistory(for: model, count: 3)
        model.beginSession()
        selectFirstTwoItems(in: model)

        let session = model.sessionGeneration
        let oldHops = MacClippyDeferredQueuePasteHops()
        startQueuePaste(on: model, hops: oldHops) {}
        waitForScheduledQueuePasteHops(oldHops, count: 3)
        let oldOperation = model.operationGeneration
        let oldToken = try XCTUnwrap(model.queuePasteCancellationToken)

        model.toggleSelection(at: 2)
        XCTAssertTrue(model.hasMultipleSelection)
        let newHops = MacClippyDeferredQueuePasteHops()
        var didClose = false
        startQueuePaste(on: model, hops: newHops) { didClose = true }
        waitForScheduledQueuePasteHops(newHops, count: 4)

        let newToken = try XCTUnwrap(model.queuePasteCancellationToken)
        assertNewQueueOwnership(
            model,
            session: session,
            oldOperation: oldOperation,
            oldToken: oldToken,
            newToken: newToken
        )

        newHops.run(at: 0)
        assertQueueProgress(model, done: 1, total: 3)
        assertStaleCallbacksPreserveNewQueue(model, oldHops: oldHops, newToken: newToken)
        finishCurrentQueue(model, hops: newHops)

        XCTAssertTrue(didClose, "a current full-success finish should still close the dock")
        XCTAssertEqual(
            eventPoster.globalPostCount,
            5,
            "the old two-item and current three-item queues each post once per item"
        )
        XCTAssertTrue(
            eventPoster.targetedProcessIdentifiers.allSatisfy { $0 == eventPoster.ownedProcessIdentifier },
            "any targeted fake post must stay scoped to this test process"
        )
    }

    @MainActor
    private func assertStaleCallbacksPreserveNewQueue(
        _ model: MacClippyDockModel,
        oldHops: MacClippyDeferredQueuePasteHops,
        newToken: MacClippyCancellationToken
    ) {
        oldHops.run(at: 2)
        XCTAssertTrue(model.queuePasteCancellationToken === newToken, "a stale finish must retain the new token")
        assertQueueProgress(model, done: 1, total: 3)

        oldHops.run(at: 0)
        oldHops.run(at: 0)
        XCTAssertTrue(model.queuePasteCancellationToken === newToken)
        assertQueueProgress(model, done: 1, total: 3)
    }

    @MainActor
    private func finishCurrentQueue(
        _ model: MacClippyDockModel,
        hops: MacClippyDeferredQueuePasteHops
    ) {
        hops.run(at: 0)
        assertQueueProgress(model, done: 2, total: 3)
        hops.run(at: 0)
        assertQueueProgress(model, done: 3, total: 3)
        hops.run(at: 0)

        XCTAssertNil(model.queuePasteProgress, "the current finish must clear its own progress")
        XCTAssertNil(model.queuePasteCancellationToken, "the current finish must clear its own cancellation token")
        guard case let .queuePasteCompleted(injectedCount, unavailableCount) = model.actionFeedback else {
            XCTFail(
                "expected completed feedback from the current operation, " +
                    "got \(String(describing: model.actionFeedback))"
            )
            return
        }
        XCTAssertEqual(injectedCount, 3)
        XCTAssertEqual(unavailableCount, 0)
    }

    @MainActor
    private func assertQueueProgress(_ model: MacClippyDockModel, done: Int, total: Int) {
        XCTAssertEqual(model.queuePasteProgress?.done, done)
        XCTAssertEqual(model.queuePasteProgress?.total, total)
    }

    @MainActor
    private func appendThreeRecords(to runtime: MacClippyRuntime) throws {
        _ = try runtime.appendTestRecord(.text("first"))
        _ = try runtime.appendTestRecord(.text("second"))
        _ = try runtime.appendTestRecord(.text("third"))
    }

    @MainActor
    private func loadHistory(for model: MacClippyDockModel, count: Int) {
        model.reload()
        MacClippyTestWait.until(
            { model.historyItems.count == count },
            timeout: 2.0,
            failOnTimeout: true
        )
    }

    @MainActor
    private func selectFirstTwoItems(in model: MacClippyDockModel) {
        model.focusSelection(at: 0)
        model.toggleSelection(at: 1)
        XCTAssertTrue(model.hasMultipleSelection)
    }

    @MainActor
    private func assertNewQueueOwnership(
        _ model: MacClippyDockModel,
        session: UInt,
        oldOperation: UInt,
        oldToken: MacClippyCancellationToken,
        newToken: MacClippyCancellationToken
    ) {
        XCTAssertEqual(model.sessionGeneration, session, "both queue operations must belong to the same dock session")
        XCTAssertNotEqual(model.operationGeneration, oldOperation, "the new queue must supersede the old operation")
        XCTAssertFalse(oldToken === newToken, "each queue operation must own a distinct cancellation token")
        XCTAssertTrue(oldToken.isCancelled, "starting a new queue must preserve cancellation of the older queue")
    }

    @MainActor
    private func startQueuePaste(
        on model: MacClippyDockModel,
        hops: MacClippyDeferredQueuePasteHops,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        let enqueueMainHop: MacClippyQueuePasteMainHop = { [hops] work in
            hops.enqueue(work)
        }
        model.pasteQueued(completion: completion, enqueueMainHop: enqueueMainHop)
    }

    @MainActor
    private func waitForScheduledQueuePasteHops(
        _ hops: MacClippyDeferredQueuePasteHops,
        count: Int
    ) {
        MacClippyTestWait.until(
            { hops.count == count },
            timeout: 2.0,
            failOnTimeout: true
        )
    }
}
