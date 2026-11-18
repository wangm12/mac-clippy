import AppKit
import MacClippyPlatformTestObjCSupport
@_spi(Testing) @testable import MacClippyPlatform
import XCTest

// Covers the snapshot-restore path the injector takes after a failed prepare
// or a paste that cannot proceed: the single clear, the write retry, and the
// write-sentinel tokens that keep a restored clipboard out of history.
final class MacClippyPasteInjectorRestoreTests: XCTestCase {
    func testFailedRestoreRetriesWriteObjectsWithoutClearingAgain() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyRestoreRetry-\(UUID().uuidString)"))
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var writeAttempts = 0
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            writeObjects: { pasteboard, items in
                writeAttempts += 1
                if writeAttempts == 1 {
                    return false
                }
                return pasteboard.writeObjects(items)
            }
        )

        XCTAssertThrowsError(try injector.prepareText("replacement")) { error in
            XCTAssertEqual(error as? MacClippyPasteboardPrepareError, .writeFailed)
        }
        XCTAssertEqual(writeAttempts, 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testRetriedRestoreLeavesOnlyTheRestoredGenerationToken() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyRestoreRetryToken-\(UUID().uuidString)"))
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let sentinel = MacClippyPasteboardWriteSentinel()
        var writeAttempts = 0
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            writeSentinel: sentinel,
            writeObjects: { pasteboard, items in
                writeAttempts += 1
                if writeAttempts == 1 {
                    return false
                }
                return pasteboard.writeObjects(items)
            }
        )

        XCTAssertThrowsError(try injector.prepareText("replacement")) { error in
            XCTAssertEqual(error as? MacClippyPasteboardPrepareError, .writeFailed)
        }
        XCTAssertEqual(writeAttempts, 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
        XCTAssertEqual(sentinel.pendingCount, 1, "the retry must not register a second token")
        XCTAssertTrue(
            sentinel.consume(changeCount: pasteboard.changeCount),
            "the only pending token must be the restored generation"
        )
        XCTAssertEqual(sentinel.pendingCount, 0, "no token may outlive the restored generation")
    }

    func testFailedRestoreAbortsWhenChangeCountMoves() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyRestoreAbort-\(UUID().uuidString)"))
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            writeObjects: { pasteboard, items in
                _ = items
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("user copy", forType: .string))
                return false
            }
        )

        XCTAssertThrowsError(try injector.prepareText("replacement")) { error in
            XCTAssertEqual(error as? MacClippyPasteboardPrepareError, .writeFailed)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "user copy")
    }

    func testNativeClearExceptionAfterMutationRestoresTheOwnedSnapshot() throws {
        let pasteboard = MacClippyMakeMalformedPasteboard(0)
        let sentinel = MacClippyPasteboardWriteSentinel()
        let injector = MacClippyPasteInjector(pasteboard: pasteboard, writeSentinel: sentinel)
        let original = injector.snapshotPasteboard(pasteboard)
        let prepared = MacClippyPasteInjector.PasteboardSnapshot(
            items: [[(type: .string, data: Data("replacement".utf8))]],
            isComplete: true,
            changeCount: original.changeCount
        )
        XCTAssertTrue(original.isComplete)

        // Exercise the production snapshot writer directly against the fake
        // NSPasteboard selector object so the fault is deterministic without
        // Launch Services or the system clipboard.
        MacClippyNativePasteboard.injectExceptionForTesting(after: "pasteboard.clear")
        let writeResult = injector.writeSnapshot(
            prepared,
            to: pasteboard,
            sentinel: sentinel,
            expectedChangeCount: original.changeCount,
            gate: nil
        )
        guard case let .failed(restoreCount?) = writeResult else {
            return XCTFail("a proven cleared generation must be returned as restorable failure")
        }
        XCTAssertEqual(restoreCount, 20)
        XCTAssertEqual(injector.restore(original, onlyIfChangeCountIs: restoreCount), .restored(changeCount: 21))

        let restored = try MacClippyNativePasteboard.string(from: pasteboard, forType: .string)
        XCTAssertEqual(restored, "fixture text")
        XCTAssertEqual(sentinel.pendingCount, 1)
        XCTAssertTrue(sentinel.consume(changeCount: try MacClippyNativePasteboard.changeCount(of: pasteboard)))
        XCTAssertEqual(sentinel.pendingCount, 0)
    }

    func testRestoreClearExceptionAfterMutationContinuesOnlyForProvenOwnedGeneration() throws {
        let pasteboard = MacClippyMakeMalformedPasteboard(0)
        let sentinel = MacClippyPasteboardWriteSentinel()
        let original = MacClippyPasteInjector(pasteboard: pasteboard).snapshotPasteboard(pasteboard)
        var writeAttempts = 0
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            writeSentinel: sentinel,
            writeObjects: { pasteboard, items in
                writeAttempts += 1
                guard writeAttempts > 1 else { return false }
                return (try? MacClippyNativePasteboard.write(items, to: pasteboard)) == true
            }
        )
        let prepared = MacClippyPasteInjector.PasteboardSnapshot(
            items: [[(type: .string, data: Data("replacement".utf8))]],
            isComplete: true,
            changeCount: original.changeCount
        )

        let writeResult = injector.writeSnapshot(
            prepared,
            to: pasteboard,
            sentinel: sentinel,
            expectedChangeCount: original.changeCount,
            gate: nil
        )
        guard case let .failed(restoreCount?) = writeResult else {
            return XCTFail("injected first write failure must return an owned generation for restore")
        }
        XCTAssertEqual(restoreCount, 20)
        MacClippyNativePasteboard.injectExceptionForTesting(after: "pasteboard.clear")
        XCTAssertEqual(injector.restore(original, onlyIfChangeCountIs: restoreCount), .restored(changeCount: 21))

        XCTAssertEqual(writeAttempts, 2, "the failed prepared write and one restore write are expected")
        XCTAssertEqual(try MacClippyNativePasteboard.string(from: pasteboard, forType: .string), "fixture text")
        XCTAssertEqual(sentinel.pendingCount, 1, "only the restored generation may retain an own-write token")
        XCTAssertTrue(sentinel.consume(changeCount: try MacClippyNativePasteboard.changeCount(of: pasteboard)))
        XCTAssertEqual(sentinel.pendingCount, 0)
    }

    func testForeignGenerationAfterClearExceptionIsNeverRestoredOver() throws {
        let pasteboard = MacClippyMakeMalformedPasteboard(9)
        let sentinel = MacClippyPasteboardWriteSentinel()
        let injector = MacClippyPasteInjector(pasteboard: pasteboard, writeSentinel: sentinel)
        let original = injector.snapshotPasteboard(pasteboard)
        let prepared = MacClippyPasteInjector.PasteboardSnapshot(
            items: [[(type: .string, data: Data("replacement".utf8))]],
            isComplete: true,
            changeCount: original.changeCount
        )
        MacClippyNativePasteboard.injectExceptionForTesting(after: "pasteboard.clear")

        let writeResult = injector.writeSnapshot(
            prepared,
            to: pasteboard,
            sentinel: sentinel,
            expectedChangeCount: original.changeCount,
            gate: nil
        )

        guard case .clipboardChanged = writeResult else {
            return XCTFail("a second generation is foreign and must not be restored over")
        }
        XCTAssertEqual(try MacClippyNativePasteboard.changeCount(of: pasteboard), 21)
        XCTAssertEqual(try MacClippyNativePasteboard.string(from: pasteboard, forType: .string), "foreign generation")
        XCTAssertEqual(sentinel.pendingCount, 0)
    }

    func testSnapshotWriterDoesNotIssueRestoreTokenAfterForeignEmptyGeneration() throws {
        let pasteboard = MacClippyMakeForeignClearAfterFailedNativeClearPasteboard()
        let sentinel = MacClippyPasteboardWriteSentinel()
        let injector = MacClippyPasteInjector(pasteboard: pasteboard, writeSentinel: sentinel)
        let coordinator = MacClippyPasteboardAccessCoordinator.shared(for: pasteboard)
        let original = injector.snapshotPasteboard(pasteboard)
        let prepared = MacClippyPasteInjector.PasteboardSnapshot(
            items: [[(type: .string, data: Data("replacement".utf8))]],
            isComplete: true,
            changeCount: original.changeCount
        )
        XCTAssertTrue(original.isComplete)

        let result = injector.writeSnapshot(
            prepared,
            to: pasteboard,
            sentinel: sentinel,
            expectedChangeCount: original.changeCount,
            gate: nil
        )
        guard case .restoreFailed = result else {
            return XCTFail("an ambiguous native clear must not issue a restore token")
        }

        XCTAssertEqual(try MacClippyNativePasteboard.changeCount(of: pasteboard), 20)
        XCTAssertTrue(try MacClippyNativePasteboard.items(of: pasteboard).isEmpty)
        XCTAssertEqual(sentinel.pendingCount, 0, "an ambiguous clear must cancel its sentinel token")
        assertCoordinatorCanBeAcquiredOnAnotherQueue(coordinator)
    }

    func testRestoreDoesNotWriteSnapshotOverForeignEmptyGenerationAfterNativeClearFailure() throws {
        let pasteboard = MacClippyMakeForeignClearAfterFailedNativeClearPasteboard()
        let sentinel = MacClippyPasteboardWriteSentinel()
        let injector = MacClippyPasteInjector(pasteboard: pasteboard, writeSentinel: sentinel)
        let original = injector.snapshotPasteboard(pasteboard)
        let coordinator = MacClippyPasteboardAccessCoordinator.shared(for: pasteboard)
        XCTAssertTrue(original.isComplete)
        XCTAssertFalse(original.items.isEmpty)

        XCTAssertEqual(injector.restore(original, onlyIfChangeCountIs: original.changeCount), .ambiguousFailure)

        XCTAssertEqual(try MacClippyNativePasteboard.changeCount(of: pasteboard), original.changeCount + 1)
        XCTAssertTrue(try MacClippyNativePasteboard.items(of: pasteboard).isEmpty)
        XCTAssertEqual(sentinel.pendingCount, 0, "an ambiguous restore clear must cancel its sentinel token")
        assertCoordinatorCanBeAcquiredOnAnotherQueue(coordinator)
    }

    private func assertCoordinatorCanBeAcquiredOnAnotherQueue(
        _ coordinator: MacClippyPasteboardAccessCoordinator
    ) {
        let acquired = expectation(description: "pasteboard coordinator reacquired from another queue")
        DispatchQueue.global(qos: .userInitiated).async {
            coordinator.withAccess { acquired.fulfill() }
        }
        wait(for: [acquired], timeout: 2)
    }
}
