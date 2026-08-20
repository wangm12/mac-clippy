import XCTest

import GRDB
import MacClippyCore

final class MacClippyFailureClassificationTests: XCTestCase {
    func testDatabaseErrorIsStorageFailure() {
        XCTAssertTrue(MacClippyFailureClassification.isStorageFailure(DatabaseError(resultCode: .SQLITE_ERROR)))
    }

    func testUnrelatedErrorIsNotStorageFailure() {
        XCTAssertFalse(MacClippyFailureClassification.isStorageFailure(CocoaError(.fileNoSuchFile)))
    }
}
