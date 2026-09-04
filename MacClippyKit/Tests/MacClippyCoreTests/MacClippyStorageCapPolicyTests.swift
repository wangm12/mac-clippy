import XCTest

@testable import MacClippyCore

final class MacClippyStorageCapPolicyTests: XCTestCase {
    func testDefaultCapsAreTenThousandItemsTwoGigabytesOfImagesAndFourGigabytesTotal() {
        XCTAssertEqual(MacClippyStorageCapPolicy.defaultMaxItems, 10_000)
        XCTAssertEqual(MacClippyStorageCapPolicy.defaultMaxImageMegabytes, 2_048)
        XCTAssertEqual(MacClippyStorageCapPolicy.defaultMaxHistoryMegabytes, 4_096)
    }

    func testHistorySettingsExposeAgePresetsNotCapEditors() {
        XCTAssertFalse(MacClippyStorageCapPolicy.exposesSettingsEditors)
        XCTAssertTrue(MacClippyStorageCapPolicy.rows().isEmpty)
        XCTAssertNil(MacClippyStorageCapPolicy.unlimitedAgeFootnote())
    }

    func testZeroFallsBackToTheDefaultCap() {
        XCTAssertEqual(
            MacClippyStorageCapPolicy.enforced(0, default: MacClippyStorageCapPolicy.defaultMaxItems),
            10_000
        )
        XCTAssertEqual(MacClippyStorageCapPolicy.enforced(500, default: 10_000), 500)
    }
}
