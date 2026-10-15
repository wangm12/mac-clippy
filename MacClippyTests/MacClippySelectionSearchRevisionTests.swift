import Foundation
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

private final class SelectionMutationState: @unchecked Sendable {
    struct Snapshot {
        let count: Int
        let error: Error?
        let rank: Double?
    }

    private let lock = NSLock()
    private var mutations = 0
    private var failure: Error?
    private var updatedRank: Double?

    func reserveMutation(maximum: Int?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let maximum, mutations >= maximum { return false }
        mutations += 1
        return true
    }

    func record(error: Error) {
        lock.lock()
        failure = error
        lock.unlock()
    }

    func record(rank: Double?) {
        lock.lock()
        updatedRank = rank
        lock.unlock()
    }

    var result: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(count: mutations, error: failure, rank: updatedRank)
    }
}

private func reindexSelectionPage(
    runtime: MacClippyRuntime,
    id: RecordID,
    state: SelectionMutationState,
    changeGlobalRank: Bool = false
) {
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        defer { completed.signal() }
        do {
            try runtime.withStoreLock {
                try runtime.searchStore.upsert(id: id, text: "common body")
                if changeGlobalRank {
                    let unrelated = try runtime.clipboardStore.append(.text("unrelated"))
                    try runtime.searchStore.upsert(id: unrelated.id, text: "unrelated")
                }
                state.record(rank: try runtime.searchStore.search(terms: ["common"], limit: 1).first?.rank)
            }
        } catch { state.record(error: error) }
    }
    XCTAssertEqual(completed.wait(timeout: .now() + 10), .success, "selection hook must release storeLock")
}

final class MacClippySelectionSearchRevisionTests: XCTestCase {
    private var root: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippySelectionRevision-\(UUID())")
        runtime = try MacClippyRuntime(paths: MacClippyPaths(rootURL: root))
    }

    override func tearDownWithError() throws {
        runtime?.afterSelectionSearchBatchForTesting = nil
        runtime?.closeForTesting()
        runtime = nil
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testBareSelectionRetriesAfterPageReindexAndGlobalRankChangeWithoutDuplicateOrMissingIDs() throws {
        let expected = try seedRecords()
        let runtime = try XCTUnwrap(runtime)
        let first = try XCTUnwrap(runtime.searchStore.search(terms: ["common"], limit: 256).first)
        let state = SelectionMutationState()
        runtime.afterSelectionSearchBatchForTesting = { scanned in
            guard scanned >= 256, state.reserveMutation(maximum: 1) else { return }
            reindexSelectionPage(runtime: runtime, id: first.id, state: state, changeGlobalRank: true)
        }
        let decrypts = runtime.clipboardStore.recordEnvelopeDecryptCount
        let ids = try runtime.historyRecordIDs(query: "common")
        XCTAssertEqual(ids.count, expected.count)
        XCTAssertEqual(Set(ids), Set(expected))
        XCTAssertEqual(state.result.count, 1)
        XCTAssertNil(state.result.error)
        XCTAssertNotEqual(state.result.rank, first.rank, "the update must exercise global rank invalidation")
        XCTAssertEqual(runtime.clipboardStore.recordEnvelopeDecryptCount, decrypts)
    }

    func testCompositeSelectionRetriesAfterPageReindexAndKeepsMetadataOnlyProjection() throws {
        let expected = try seedRecords()
        let runtime = try XCTUnwrap(runtime)
        let id = try XCTUnwrap(runtime.searchStore.search(terms: ["common"], limit: 256).first).id
        let state = SelectionMutationState()
        runtime.afterSelectionSearchBatchForTesting = { scanned in
            guard scanned >= 256, state.reserveMutation(maximum: 1) else { return }
            reindexSelectionPage(runtime: runtime, id: id, state: state)
        }
        let decrypts = runtime.clipboardStore.recordEnvelopeDecryptCount
        let ids = try runtime.historyRecordIDs(query: "common type:text")
        XCTAssertEqual(ids.count, expected.count)
        XCTAssertEqual(Set(ids), Set(expected))
        XCTAssertEqual(state.result.count, 1)
        XCTAssertNil(state.result.error)
        XCTAssertEqual(runtime.clipboardStore.recordEnvelopeDecryptCount, decrypts)
    }

    func testSelectionReportsChangingIndexAfterBoundedRetries() throws {
        _ = try seedRecords()
        let runtime = try XCTUnwrap(runtime)
        let id = try XCTUnwrap(runtime.searchStore.search(terms: ["common"], limit: 256).first).id
        let state = SelectionMutationState()
        runtime.afterSelectionSearchBatchForTesting = { scanned in
            guard scanned >= 256, state.reserveMutation(maximum: nil) else { return }
            reindexSelectionPage(runtime: runtime, id: id, state: state)
        }
        XCTAssertThrowsError(try runtime.historyRecordIDs(query: "common")) {
            XCTAssertEqual($0 as? MacClippyHistoryPageError, .searchIndexChanged)
        }
        XCTAssertEqual(state.result.count, 4)
        XCTAssertNil(state.result.error)
    }

    func testCancellationDuringPageReindexReturnsNoPartialSelection() throws {
        _ = try seedRecords()
        let runtime = try XCTUnwrap(runtime)
        let id = try XCTUnwrap(runtime.searchStore.search(terms: ["common"], limit: 256).first).id
        let state = SelectionMutationState()
        let cancellation = MacClippyCancellationToken()
        runtime.afterSelectionSearchBatchForTesting = { scanned in
            guard scanned >= 256, state.reserveMutation(maximum: 1) else { return }
            reindexSelectionPage(runtime: runtime, id: id, state: state)
            cancellation.cancel()
        }
        XCTAssertTrue(try runtime.historyRecordIDs(query: "common", shouldCancel: { cancellation.isCancelled }).isEmpty)
        XCTAssertEqual(state.result.count, 1)
        XCTAssertNil(state.result.error)
    }

    private func seedRecords() throws -> [RecordID] {
        try (0..<512).map { _ in
            let meta = try runtime.appendTestRecord(.text("common body"))
            try runtime.searchStore.upsert(id: meta.id, text: "common body")
            return meta.id
        }
    }
}
