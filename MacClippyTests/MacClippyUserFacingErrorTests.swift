import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyUserFacingErrorTests: XCTestCase {
    func testStoreErrorsMapToSpecificCopy() {
        XCTAssertEqual(
            MacClippyUserFacingError.message(for: MacClippyStoreError.recordNotFound),
            MacClippyUserFacingError.missingItem
        )
        XCTAssertEqual(
            MacClippyUserFacingError.message(for: MacClippyStoreError.invalidStoredRecord),
            MacClippyUserFacingError.corruptItem
        )
    }

    func testPermissionErrorsMapToPermissionCopy() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError,
            userInfo: nil
        )
        XCTAssertEqual(
            MacClippyUserFacingError.message(for: error),
            MacClippyUserFacingError.permission
        )
    }

    func testGRDBDomainMapsToStorageCopy() {
        let error = NSError(domain: "GRDB.DatabaseError", code: 1, userInfo: nil)
        XCTAssertEqual(
            MacClippyUserFacingError.message(for: error, fallback: "fallback"),
            MacClippyUserFacingError.storage
        )
    }

    func testPasteboardPrepareErrorsMapToClipboardCopy() {
        XCTAssertEqual(
            MacClippyUserFacingError.message(for: MacClippyPasteboardPrepareError.incompleteSnapshot),
            MacClippyUserFacingError.clipboardBusy
        )
        XCTAssertEqual(
            MacClippyUserFacingError.message(for: MacClippyPasteboardPrepareError.writeFailed),
            MacClippyUserFacingError.clipboardWrite
        )
        XCTAssertEqual(
            MacClippyUserFacingError.message(for: MacClippyPasteboardPrepareError.restoreFailed),
            MacClippyUserFacingError.clipboardRestore
        )
    }
}
