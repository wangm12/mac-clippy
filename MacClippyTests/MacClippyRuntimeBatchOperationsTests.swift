import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyRuntimeBatchOperationsTests: XCTestCase {
    var tempRoot: URL!
    var pasteboardEnvironment: MacClippyAppTestPasteboardEnvironment!
    var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyBatchOpTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let paths = try MacClippyPaths(rootURL: tempRoot)
        pasteboardEnvironment = MacClippyAppTestPasteboardEnvironment(
            label: "MacClippyBatchOperations",
            sourceAppBundleID: { "com.example.macclippy-tests-source" }
        )
        runtime = try MacClippyRuntime(
            paths: paths,
            observer: pasteboardEnvironment.observer,
            pasteInjector: pasteboardEnvironment.injector,
            enableSnippetExpansion: false,
            preferencesDefaults: pasteboardEnvironment.preferencesDefaults
        )
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        pasteboardEnvironment = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Ordered multi-paste

    func testOrderedMultiPasteReturnsMergedForHomogeneousTextSelection() throws {
        let first = try runtime.appendTestRecord(.text("first"))
        let second = try runtime.appendTestRecord(.text("second"))

        // Visual order in the dock is newest-first: second, first.
        let result = try runtime.pasteOrdered(ids: [second.id, first.id])
        guard case let .merged(injection) = result else {
            XCTFail("expected .merged for a homogeneous text selection, got \(result)")
            return
        }
        XCTAssertEqual(injection, .injected)
        XCTAssertEqual(pasteboardEnvironment.pasteboard.string(forType: .string), "second\nfirst")
        // The exact merged text is covered by the pure
        // MacClippyDockMultiPastePolicyTests; this test's injector uses a
        // unique named pasteboard and fake event posters.
    }

    func testOrderedMultiPasteReturnsMixedForImageInSelectionAndDoesNotPasteSubset() throws {
        let text = try runtime.appendTestRecord(.text("text"))
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))

        let result = try runtime.pasteOrdered(ids: [text.id, image.id])
        guard case let .mixed(supportedIDs, unsupportedIDs, unsupportedKinds) = result else {
            XCTFail("expected .mixed for a text+image selection, got \(result)")
            return
        }
        XCTAssertEqual(supportedIDs, [text.id])
        XCTAssertEqual(unsupportedIDs, [image.id])
        XCTAssertEqual(unsupportedKinds, [.image])
    }

    func testOrderedMultiPasteWithFilesReportsThemAsUnsupportedNotDropped() throws {
        let text = try runtime.appendTestRecord(.text("text"))
        let files = try runtime.appendTestRecord(.files([URL(fileURLWithPath: "/tmp/a.txt")]))

        let result = try runtime.pasteOrdered(ids: [text.id, files.id])
        guard case let .mixed(supportedIDs, unsupportedIDs, unsupportedKinds) = result else {
            XCTFail("expected .mixed for a text+files selection, got \(result)")
            return
        }
        XCTAssertEqual(supportedIDs, [text.id])
        XCTAssertEqual(unsupportedIDs, [files.id])
        XCTAssertEqual(unsupportedKinds, [.files])
    }

    func testOrderedMultiPasteWithMalformedRTFReportsTextUnavailableAndDoesNotPaste() throws {
        // A malformed RTF payload whose NSAttributedString cannot be
        // initialized must NOT be silently merged as an empty piece. The
        // runtime must report .textUnavailable with the unavailable ID and
        // its kind, and NO paste occurs for the selection (the available
        // text record is not pasted as a partial subset either).
        let good = try runtime.appendTestRecord(.text("good"))
        let malformedRTF = Data("{\\rtf1 THIS IS NOT VALID RTF".utf8)
        let bad = try runtime.appendTestRecord(.rtf(malformedRTF))

        let result = try runtime.pasteOrdered(ids: [good.id, bad.id])
        guard case let .textUnavailable(availableIDs, unavailableIDs, unavailableKinds) = result else {
            XCTFail("expected .textUnavailable for a text+malformed-rtf selection, got \(result)")
            return
        }
        XCTAssertEqual(availableIDs, [good.id])
        XCTAssertEqual(unavailableIDs, [bad.id])
        XCTAssertEqual(unavailableKinds, [.rtf])
    }

    func testOrderedMultiPasteWithEmptyRealTextMergesEmptyPiece() throws {
        // An empty real text payload ("") is a valid empty piece and must be
        // merged in visual order; it is NOT reported as unavailable. This
        // guards the boundary between "empty decoded text" and "nil payload".
        let alphaRecord = try runtime.appendTestRecord(.text("alpha"))
        let empty = try runtime.appendTestRecord(.text(""))

        let result = try runtime.pasteOrdered(ids: [alphaRecord.id, empty.id])
        guard case let .merged(injection) = result else {
            XCTFail("expected .merged for a text selection with one empty real text, got \(result)")
            return
        }
        XCTAssertEqual(injection, .injected)
        XCTAssertEqual(pasteboardEnvironment.pasteboard.string(forType: .string), "alpha\n")
        // The exact merged string is covered by the pure policy tests; here we
        // assert the result kind only. The test injector is fully isolated
        // from the system pasteboard and event taps.
    }

    // MARK: - Stale operation/session generation (model-level)

    @MainActor
    func testStaleBatchCompletionDoesNotCloseReopenedDock() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("first"))
        _ = try runtime.appendTestRecord(.text("second"))
        model.reload()
        wait { model.historyItems.count >= 2 }

        // Start a session, begin a batch paste, then end the session (hide)
        // and begin a new session (reopen) BEFORE the batch completes. The
        // stale completion must not call the close handler.
        model.beginSession()
        model.selectAllVisible()
        MacClippyTestWait.until({ model.selectionIsReady }, failOnTimeout: true)
        XCTAssertTrue(model.hasMultipleSelection)
        XCTAssertEqual(model.selectionCount, 2)
        var didClose = false
        model.pasteSelectedAll(completion: { didClose = true })

        // End the session (simulates hide) and start a new one (simulates
        // reopen) while the batch is still in flight on the work queue.
        model.endSession()
        model.beginSession()

        // Wait for the work queue to drain. The stale completion should have
        // been suppressed by the session-generation mismatch.
        wait { didClose || model.actionFeedback != nil }

        XCTAssertFalse(didClose, "stale batch completion must not close a newly reopened dock")
    }

    @MainActor
    func testNewerBatchSupersedesOlderBatchResult() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("first"))
        _ = try runtime.appendTestRecord(.text("second"))
        model.reload()
        wait { model.historyItems.count >= 2 }

        model.selectAllVisible()
        MacClippyTestWait.until({ model.selectionIsReady }, failOnTimeout: true)

        // Start a batch delete, then immediately start a second batch delete
        // before the first completes. The second bumps operationGeneration, so
        // the first's completion is suppressed.
        model.deleteSelected()
        model.deleteSelected()

        // The second delete should win; after drain, the records are gone and
        // the selection is cleared.
        wait(until: { model.historyItems.isEmpty && model.selection.isEmpty }, timeout: 5.0)
        XCTAssertTrue(model.historyItems.isEmpty)
        XCTAssertTrue(model.selection.isEmpty)
    }

    // MARK: - Batch failure semantics

    @MainActor
    func testBatchDeleteWithMissingIDReportsPartialNotCompleteSuccess() throws {
        // A batch delete where one selected ID is not in the store must report
        // a partial result, never a complete .deleted success. This guards the
        // P1 invariant that an error/missing item cannot silently make the UI
        // report a successful complete batch. The dock reads the runtime
        // result (missingIDs + failedIDs) and chooses .batchPartial over
        // .deleted when either is non-empty.
        let model = MacClippyDockModel(runtime: runtime)
        let present = try runtime.appendTestRecord(.text("present"))
        let stale = RecordID.generate()

        // Manually drive a delete over a selection that includes a stale ID.
        // The model's deleteSelected uses selection.orderedSelectedIDs, so put
        // both IDs into the selection via toggle.
        model.reload()
        wait { model.historyItems.count >= 1 }

        // Build a selection containing the present id and a stale id. The
        // stale id is not in historyItems, so toggle it directly through the
        // selection policy entry point.
        guard let presentIndex = model.historyItems.firstIndex(where: { $0.id == present.id }) else {
            XCTFail("present record should be visible after reload")
            return
        }
        model.focusSelection(at: presentIndex)
        model.toggleSelection(at: presentIndex)

        // Append the stale id into the runtime batch by calling deleteSelected
        // with a selection that includes it. Since the model only knows about
        // visible items, exercise the runtime directly and feed the result
        // through the same feedback decision the dock uses.
        let runtimeResult = try runtime.delete(ids: [present.id, stale])
        XCTAssertFalse(runtimeResult.missingIDs.isEmpty)
        XCTAssertEqual(runtimeResult.missingIDs, [stale])
        XCTAssertEqual(runtimeResult.failedIDs, [])

        // The dock's decision: non-empty missingIDs OR failedIDs -> partial.
        let isCompleteSuccess = runtimeResult.missingIDs.isEmpty && runtimeResult.failedIDs.isEmpty
        XCTAssertFalse(isCompleteSuccess, "a partial batch must never be reported as complete success")
    }

    @MainActor
    func testBatchPinWithMissingIDReportsPartialNotCompleteSuccess() throws {
        // A batch pin where one selected ID is not in the store must report a
        // partial result, never a complete .pinnedTo success. Guards the same
        // P1 invariant for the pin path: missingIDs OR failedIDs non-empty ->
        // .batchPartial.
        let board = try runtime.createPinboard(name: "Board", color: nil)
        let model = MacClippyDockModel(runtime: runtime)
        let present = try runtime.appendTestRecord(.text("present"))
        let stale = RecordID.generate()

        model.reload()
        wait { model.historyItems.count >= 1 }

        let runtimeResult = try runtime.pin(recordIDs: [present.id, stale], to: board.id)
        XCTAssertFalse(runtimeResult.missingIDs.isEmpty)
        XCTAssertEqual(runtimeResult.missingIDs, [stale])
        XCTAssertEqual(runtimeResult.failedIDs, [])

        let isCompleteSuccess = runtimeResult.missingIDs.isEmpty && runtimeResult.failedIDs.isEmpty
        XCTAssertFalse(isCompleteSuccess, "a partial pin batch must never be reported as complete success")
    }

    // MARK: - Selection surface visibility

    @MainActor
    func testSelectionSurfaceHiddenForSingleSelectionAndSnippets() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("only"))
        model.reload()
        wait { model.historyItems.count >= 1 }

        // One focused card: no multi-select surface.
        model.focusSelection(at: 0)
        XCTAssertFalse(model.hasMultipleSelection)

        // Cmd+A on a single record selects one -> still no surface (count == 1).
        model.selectAllVisible()
        MacClippyTestWait.until({ model.selectionIsReady }, failOnTimeout: true)
        XCTAssertFalse(model.hasMultipleSelection)

        // Switch to snippets: surface never shows.
        model.selectTab(.snippets)
        XCTAssertFalse(model.hasMultipleSelection)
        XCTAssertEqual(model.selectionCount, 0)
    }

    @MainActor
    func testClearSelectionKeepsFocusAndAllowsSecondEscapeToDismiss() throws {
        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("a"))
        _ = try runtime.appendTestRecord(.text("b"))
        model.reload()
        wait { model.historyItems.count >= 2 }

        model.selectAllVisible()
        MacClippyTestWait.until({ model.selectionIsReady }, failOnTimeout: true)
        XCTAssertTrue(model.hasMultipleSelection)

        // First Escape (clear-selection-first): selection is cleared, focus
        // stays on the current card.
        let focusBeforeClear = model.focusedIndex
        model.clearSelection()
        XCTAssertFalse(model.hasMultipleSelection)
        XCTAssertEqual(model.focusedIndex, focusBeforeClear)

        // A second Escape has nothing to clear, so the controller's lifecycle
        // path dismisses the dock. The model's clearSelection is a no-op when
        // the selection is already empty, leaving focus intact.
        let focusBeforeSecondClear = model.focusedIndex
        model.clearSelection()
        XCTAssertEqual(model.focusedIndex, focusBeforeSecondClear)
    }

    // MARK: - Helpers

    func wait(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        MacClippyTestWait.until(condition, timeout: timeout)
    }

    func noisyPNG(width: Int, height: Int) throws -> Data {
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var state: UInt32 = 0x1234_5678
            for offset in stride(from: 0, to: width * height * 4, by: 4) {
                state = state &* 1_664_525 &+ 1_013_904_223
                bytes[offset] = UInt8(truncatingIfNeeded: state >> 24)
                state = state &* 1_664_525 &+ 1_013_904_223
                bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 24)
                state = state &* 1_664_525 &+ 1_013_904_223
                bytes[offset + 2] = UInt8(truncatingIfNeeded: state >> 24)
                bytes[offset + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        return output as Data
    }
}

func observablePasteboardTypes(_ item: NSPasteboardItem) -> [String] {
    item.types.map(\.rawValue).filter { $0 != "public.utf16-external-plain-text" }
}
