import XCTest

@testable import MacClippyPlatform

final class MacClippyDockHistoryRefreshPolicyTests: XCTestCase {
    func testExternalCaptureUsesTheSameDebounceWindowAsTypedSearch() {
        XCTAssertEqual(
            MacClippyDockHistoryRefreshPolicy.externalChangeDebounceNanoseconds,
            120_000_000
        )
    }

    func testOnlyAnOpenHistorySessionReloadsOnExternalCapture() {
        XCTAssertTrue(
            MacClippyDockHistoryRefreshPolicy.shouldReloadForExternalHistoryChange(
                isSessionActive: true,
                isHistoryTab: true
            )
        )
        XCTAssertFalse(
            MacClippyDockHistoryRefreshPolicy.shouldReloadForExternalHistoryChange(
                isSessionActive: false,
                isHistoryTab: true
            )
        )
        XCTAssertFalse(
            MacClippyDockHistoryRefreshPolicy.shouldReloadForExternalHistoryChange(
                isSessionActive: true,
                isHistoryTab: false
            )
        )
    }
}
