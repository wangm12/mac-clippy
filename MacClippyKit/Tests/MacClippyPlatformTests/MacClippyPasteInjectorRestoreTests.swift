import AppKit
import MacClippyPlatform
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
            preparer: { _, pasteboard in
                pasteboard.clearContents()
                return false
            },
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
            preparer: { _, pasteboard in
                pasteboard.clearContents()
                return false
            },
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
            preparer: { _, pasteboard in
                pasteboard.clearContents()
                return false
            },
            writeObjects: { pasteboard, items in
                _ = items
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setString("user copy", forType: .string))
                return false
            }
        )

        XCTAssertThrowsError(try injector.prepareText("replacement")) { error in
            XCTAssertEqual(error as? MacClippyPasteboardPrepareError, .restoreFailed)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "user copy")
    }
}
