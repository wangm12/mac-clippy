import AppKit
import Foundation
import XCTest

import MacClippyPlatformTestObjCSupport
@_spi(Testing) @testable import MacClippyPlatform

final class MacClippyMalformedNativePasteboardTests: XCTestCase {
    private enum Mode {
        static let itemsNotArray = 1
        static let itemsContainWrongType = 2
        static let boardTypesNotArray = 3
        static let boardTypesContainWrongType = 4
        static let itemTypesNotArray = 5
        static let itemTypesContainWrongType = 6
        static let itemDataWrongType = 7
        static let itemStringWrongType = 8
    }

    func testMalformedNativeArrayContainersAndElementsAreRejected() {
        let malformedItemModes = [
            (Mode.itemTypesNotArray, "pasteboard.item-types"),
            (Mode.itemTypesContainWrongType, "pasteboard.item-types"),
            (Mode.itemDataWrongType, "pasteboard.item-data")
        ]

        for (mode, operation) in malformedItemModes {
            let pasteboard = MacClippyMakeMalformedPasteboard(Int(mode))
            let snapshot = makeInjector(pasteboard).snapshotPasteboard(pasteboard)
            XCTAssertFalse(snapshot.isComplete, "mode \(mode) must not be accepted as an empty snapshot")

            let reader = MacClippySystemPasteboardReader(pasteboard: pasteboard, sourceAppBundleID: { nil })
            guard case let .failed(failure) = reader.readOutcome(shouldContinue: { true }) else {
                return XCTFail("mode \(mode) must produce a failed read outcome")
            }
            XCTAssertEqual(failure.operation, operation)
        }
    }

    func testMalformedPasteboardItemsAndBoardTypesAreRejected() throws {
        for mode in [Mode.itemsNotArray, Mode.itemsContainWrongType] {
            let pasteboard = MacClippyMakeMalformedPasteboard(Int(mode))
            let snapshot = makeInjector(pasteboard).snapshotPasteboard(pasteboard)
            XCTAssertFalse(snapshot.isComplete)
            XCTAssertTrue(snapshot.items.isEmpty)

            XCTAssertThrowsError(try MacClippyNativePasteboard.items(of: pasteboard)) { error in
                XCTAssertEqual((error as? MacClippyMalformedNativePasteboardResult)?.operation, "pasteboard.items")
            }
        }

        for mode in [Mode.boardTypesNotArray, Mode.boardTypesContainWrongType] {
            let pasteboard = MacClippyMakeMalformedPasteboard(Int(mode))
            XCTAssertThrowsError(try MacClippyNativePasteboard.boardTypes(of: pasteboard)) { error in
                XCTAssertEqual(
                    (error as? MacClippyMalformedNativePasteboardResult)?.operation,
                    "pasteboard.board-types"
                )
            }
        }
    }

    func testMalformedNativeStringIsRejectedAndIncompleteSnapshotIsNeverOverwritten() throws {
        let item = MacClippyMakeMalformedPasteboardItem(Int(Mode.itemStringWrongType))
        XCTAssertThrowsError(try MacClippyNativePasteboard.string(from: item, forType: .string)) { error in
            XCTAssertEqual((error as? MacClippyMalformedNativePasteboardResult)?.operation, "pasteboard.item-string")
        }

        let pasteboard = MacClippyMakeMalformedPasteboard(Int(Mode.itemDataWrongType))
        let injector = makeInjector(pasteboard)
        XCTAssertThrowsError(try injector.prepareText("replacement")) { error in
            XCTAssertEqual(error as? MacClippyPasteboardPrepareError, .incompleteSnapshot)
        }
        XCTAssertEqual(try MacClippyNativePasteboard.changeCount(of: pasteboard), 19)
        XCTAssertEqual(try MacClippyNativePasteboard.string(from: pasteboard, forType: .string), "fixture text")
    }

    private func makeInjector(_ pasteboard: NSPasteboard) -> MacClippyPasteInjector {
        MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { false },
            postEvents: { _, _ in }
        )
    }
}
