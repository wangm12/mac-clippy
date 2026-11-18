import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

// Focused tests for the mixed-content sequential queue paste feature. Queue
// paste processes the ordered selected IDs one at a time in visual order,
// injecting a separate Cmd+V per record so mixed selections (text + image +
// files) can each be consumed by the target app. This is NOT the homogeneous-
// only pasteOrdered path. These tests use a recording injector whose
// postEvents closure counts every paste keystroke (and can be switched to
// .preparedForManualPaste), mirroring the Dock's paste-result policy.
final class MacClippyQueuePasteTests: XCTestCase {
    private var tempRoot: URL!
    private var pasteboard: NSPasteboard!
    private var postedEventCount: Int = 0
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyQueuePasteTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyQueuePaste-\(UUID().uuidString)"))
        postedEventCount = 0

        let paths = try MacClippyPaths(rootURL: tempRoot)
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { [weak self] _, _ in
                self?.postedEventCount &+= 1
            },
            postEventsToProcess: { [weak self] _, _, _ in
                self?.postedEventCount &+= 1
            }
        )
        runtime = try MacClippyRuntime(paths: paths, pasteInjector: injector)
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        pasteboard = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Runtime: mixed-content order and frequency bumps

    func testPasteQueuedMixedTextImageFilesInjectsEachInOrderAndBumpsFrequency() throws {
        let text = try runtime.appendTestRecord(.text("alpha"))
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))
        let files = try runtime.appendTestRecord(.files([URL(fileURLWithPath: "/tmp/one.txt")]))

        // Visual order: text, image, files. Each record gets its own paste.
        let result = try runtime.pasteQueued(ids: [text.id, image.id, files.id])

        guard case let .completed(injectedIDs, unavailableIDs, unavailableKinds) = result else {
            XCTFail("expected .completed for a fully-pasteable mixed selection, got \(result)")
            return
        }
        XCTAssertEqual(injectedIDs, [text.id, image.id, files.id], "every record should be injected in visual order")
        XCTAssertTrue(unavailableIDs.isEmpty, "no record should be unavailable")
        XCTAssertTrue(unavailableKinds.isEmpty)

        // One Cmd+V per record => three posted events.
        XCTAssertEqual(postedEventCount, 3, "pasteQueued must post one paste keystroke per record")

        // The last injected record's content is what the pasteboard holds now
        // (files). The earlier writes are overwritten in turn; this confirms
        // each record was prepared and injected.
        let pastedURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertEqual(pastedURLs, [URL(fileURLWithPath: "/tmp/one.txt")])

        // Frequency bumps only for injected records, exactly once each.
        let metas = try runtime.history(limit: 10, query: "")
        let byID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0.meta.frequency) })
        XCTAssertEqual(byID[text.id], 1, "injected text frequency must bump once")
        XCTAssertEqual(byID[image.id], 1, "injected image frequency must bump once")
        XCTAssertEqual(byID[files.id], 1, "injected files frequency must bump once")
    }

    func testPasteQueuedFollowsSuppliedVisualOrderNotInsertionOrder() throws {
        let first = try runtime.appendTestRecord(.text("first"))
        let second = try runtime.appendTestRecord(.text("second"))
        let third = try runtime.appendTestRecord(.text("third"))

        // Supply a non-insertion visual order and assert injection follows it.
        let result = try runtime.pasteQueued(ids: [third.id, first.id, second.id])

        guard case let .completed(injectedIDs, _, _) = result else {
            XCTFail("expected .completed, got \(result)")
            return
        }
        XCTAssertEqual(
            injectedIDs,
            [third.id, first.id, second.id],
            "injection order must follow the supplied visual order"
        )
        XCTAssertEqual(postedEventCount, 3)

        // The last injected record is second; the pasteboard holds its text.
        XCTAssertEqual(pasteboard.string(forType: .string), "second")
    }

    // MARK: - Runtime: malformed RTF / missing record explicit unavailable

    func testPasteQueuedMalformedRTFIsExplicitlyUnavailableAndContinuesWithLaterRecords() throws {
        let good = try runtime.appendTestRecord(.text("good"))
        let malformedRTF = Data("{\\rtf1 THIS IS NOT VALID RTF".utf8)
        let bad = try runtime.appendTestRecord(.rtf(malformedRTF))
        let later = try runtime.appendTestRecord(.text("later"))

        // good, bad(malformed), later: the malformed RTF must be reported
        // unavailable and the queue must CONTINUE with `later`.
        let result = try runtime.pasteQueued(ids: [good.id, bad.id, later.id])

        guard case let .completed(injectedIDs, unavailableIDs, unavailableKinds) = result else {
            XCTFail("expected .completed, got \(result)")
            return
        }
        XCTAssertEqual(injectedIDs, [good.id, later.id], "good and later must be injected; bad must not")
        XCTAssertEqual(unavailableIDs, [bad.id], "the malformed RTF record must be explicitly unavailable")
        XCTAssertEqual(unavailableKinds, [.rtf], "the unavailable kind must be rtf")

        // Two injections (good + later), NOT three: bad is not injected.
        XCTAssertEqual(postedEventCount, 2, "the malformed record must not post a paste keystroke")

        // The last injected record is `later`; the pasteboard holds its text.
        XCTAssertEqual(pasteboard.string(forType: .string), "later")

        // Frequency: good and later bumped; bad did not.
        let metas = try runtime.history(limit: 10, query: "")
        let byID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0.meta.frequency) })
        XCTAssertEqual(byID[good.id], 1)
        XCTAssertEqual(byID[later.id], 1)
        XCTAssertEqual(byID[bad.id], 0, "the malformed record must not bump frequency")
    }

    func testPasteQueuedMissingRecordIsExplicitlyUnavailableAndContinues() throws {
        let good = try runtime.appendTestRecord(.text("good"))
        // A record id that was never appended: body(for:) throws recordNotFound.
        let missing = RecordID.generate()
        let later = try runtime.appendTestRecord(.text("later"))

        let result = try runtime.pasteQueued(ids: [good.id, missing, later.id])

        guard case let .completed(injectedIDs, unavailableIDs, unavailableKinds) = result else {
            XCTFail("expected .completed, got \(result)")
            return
        }
        XCTAssertEqual(injectedIDs, [good.id, later.id], "good and later must be injected; missing must not")
        XCTAssertEqual(unavailableIDs, [missing], "the missing record must be explicitly unavailable")
        XCTAssertEqual(unavailableKinds, [.unsupported], "a body that cannot be read reports .unsupported")

        XCTAssertEqual(postedEventCount, 2, "the missing record must not post a paste keystroke")
        XCTAssertEqual(pasteboard.string(forType: .string), "later")

        let metas = try runtime.history(limit: 10, query: "")
        let byID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0.meta.frequency) })
        XCTAssertEqual(byID[good.id], 1)
        XCTAssertEqual(byID[later.id], 1)
    }

    // MARK: - Runtime: untrusted / manual-stop behavior

    func testPasteQueuedManualPasteRequiredStopsWithCurrentAndRemainingAndNoExtraEvents() throws {
        // Build a trusted runtime first so the first record injects, then
        // switch the injector to manual fallback for the second record to
        // simulate Accessibility becoming unavailable mid-queue.
        _ = try runtime.appendTestRecord(.text("first"))
        _ = try runtime.appendTestRecord(.text("second"))
        _ = try runtime.appendTestRecord(.text("third"))

        // Recreate the runtime with an injector that returns manual fallback
        // for the second and third records (trusted for the first only). We do
        // this by toggling a flag inside postEvents is too late (inject already
        // returned injected), so instead use a custom isProcessTrusted that
        // flips to false after the first successful prepare.
        var trusted = true
        let paths = try MacClippyPaths(rootURL: tempRoot)
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { trusted },
            postEvents: { [weak self] _, _ in
                self?.postedEventCount &+= 1
            },
            postEventsToProcess: { [weak self] _, _, _ in
                self?.postedEventCount &+= 1
            }
        )
        let flippingRuntime = try MacClippyRuntime(paths: paths, pasteInjector: injector)
        _ = try flippingRuntime.appendTestRecord(.text("first-dup"))

        // We want a clean store for the flip test; reuse the original runtime's
        // records by recreating them in the flipping runtime's store. Simpler:
        // perform the whole test against flippingRuntime with its own records.
        let firstRecord = try flippingRuntime.appendTestRecord(.text("first"))
        let secondRecord = try flippingRuntime.appendTestRecord(.text("second"))
        let thirdRecord = try flippingRuntime.appendTestRecord(.text("third"))

        // Flip trust to false BEFORE calling pasteQueued so the very first
        // inject returns preparedForManualPaste and we can assert the stop shape
        // cleanly (current = first, remaining = first..third).
        trusted = false
        let result = try flippingRuntime.pasteQueued(ids: [firstRecord.id, secondRecord.id, thirdRecord.id])

        assertManualStop(
            result,
            injectedIDs: [],
            preparedID: firstRecord.id,
            remainingIDs: [firstRecord.id, secondRecord.id, thirdRecord.id],
            pasteboardText: "first"
        )

        // No events posted because the injector never reached postEvents.
        XCTAssertEqual(postedEventCount, 0, "a manual stop must not post any paste keystroke")

        // No frequency bumps on a manual stop at the first record.
        let metas = try flippingRuntime.history(limit: 10, query: "")
        let byID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0.meta.frequency) })
        XCTAssertEqual(byID[firstRecord.id], 0)
        XCTAssertEqual(byID[secondRecord.id], 0)
        XCTAssertEqual(byID[thirdRecord.id], 0)
    }

    func testPasteQueuedManualPasteRequiredMidQueueStopsAndReportsRemaining() throws {
        // First record injects (trusted), then trust flips off so the second
        // record returns preparedForManualPaste. The queue must stop with the
        // current id = second and remaining = second..last, and no further
        // events may be posted.
        var trusted = true
        let paths = try MacClippyPaths(rootURL: tempRoot)
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { trusted },
            postEvents: { [weak self] _, _ in
                self?.postedEventCount &+= 1
                // Flip trust off AFTER the first successful post so the next
                // inject returns preparedForManualPaste.
                trusted = false
            },
            postEventsToProcess: { [weak self] _, _, _ in
                self?.postedEventCount &+= 1
                trusted = false
            }
        )
        let flippingRuntime = try MacClippyRuntime(paths: paths, pasteInjector: injector)
        let first = try flippingRuntime.appendTestRecord(.text("first"))
        let second = try flippingRuntime.appendTestRecord(.text("second"))
        let third = try flippingRuntime.appendTestRecord(.text("third"))

        let result = try flippingRuntime.pasteQueued(ids: [first.id, second.id, third.id])

        assertManualStop(
            result,
            injectedIDs: [first.id],
            preparedID: second.id,
            remainingIDs: [second.id, third.id],
            pasteboardText: "second"
        )

        // Exactly one event (the first record); the manual stop posted none.
        XCTAssertEqual(postedEventCount, 1, "only the first record may post a paste keystroke")

        // Frequency bumped only for the injected first record.
        let metas = try flippingRuntime.history(limit: 10, query: "")
        let byID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0.meta.frequency) })
        XCTAssertEqual(byID[first.id], 1)
        XCTAssertEqual(byID[second.id], 0, "the manual-stop record must not bump frequency")
        XCTAssertEqual(byID[third.id], 0, "the not-yet-attempted record must not bump frequency")
    }

    private func assertManualStop(
        _ result: MacClippyQueuePasteResult,
        injectedIDs expectedInjectedIDs: [RecordID],
        preparedID expectedPreparedID: RecordID,
        remainingIDs expectedRemainingIDs: [RecordID],
        pasteboardText expectedPasteboardText: String
    ) {
        guard case let .preparedForManualPaste(
            injectedIDs,
            unavailableIDs,
            unavailableKinds,
            preparedID,
            remainingIDs
        ) = result else {
            XCTFail("expected .preparedForManualPaste, got \(result)")
            return
        }
        XCTAssertEqual(injectedIDs, expectedInjectedIDs)
        XCTAssertTrue(unavailableIDs.isEmpty)
        XCTAssertTrue(unavailableKinds.isEmpty)
        XCTAssertEqual(preparedID, expectedPreparedID)
        XCTAssertEqual(remainingIDs, expectedRemainingIDs)
        XCTAssertEqual(pasteboard.string(forType: .string), expectedPasteboardText)
    }
}

extension MacClippyQueuePasteTests {
    func testPasteQueuedCancellationReportsRemainingInsteadOfCompleted() throws {
        var shouldCancel = false
        let cancellationRoot = tempRoot.appendingPathComponent("cancelled-queue", isDirectory: true)
        let paths = try MacClippyPaths(rootURL: cancellationRoot)
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { [weak self] _, _ in
                self?.postedEventCount &+= 1
                shouldCancel = true
            },
            postEventsToProcess: { [weak self] _, _, _ in
                self?.postedEventCount &+= 1
                shouldCancel = true
            }
        )
        let cancellingRuntime = try MacClippyRuntime(paths: paths, pasteInjector: injector)
        defer { cancellingRuntime.closeForTesting() }
        let first = try cancellingRuntime.appendTestRecord(.text("first"))
        let second = try cancellingRuntime.appendTestRecord(.text("second"))
        let third = try cancellingRuntime.appendTestRecord(.text("third"))

        let result = try cancellingRuntime.pasteQueued(
            ids: [first.id, second.id, third.id],
            shouldCancel: { shouldCancel }
        )

        guard case let .cancelled(injectedIDs, unavailableIDs, _, remainingIDs) = result else {
            XCTFail("expected explicit cancellation after the first injected item, got \(result)")
            return
        }
        XCTAssertEqual(injectedIDs, [first.id])
        XCTAssertTrue(unavailableIDs.isEmpty)
        XCTAssertEqual(remainingIDs, [second.id, third.id])
        XCTAssertEqual(postedEventCount, 1)

        let metas = try cancellingRuntime.history(limit: 10, query: "")
        let byID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0.meta.frequency) })
        XCTAssertEqual(byID[first.id], 1)
        XCTAssertEqual(byID[second.id], 0)
        XCTAssertEqual(byID[third.id], 0)
    }
}
