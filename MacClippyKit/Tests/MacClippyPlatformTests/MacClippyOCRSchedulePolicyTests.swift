import XCTest

@testable import MacClippyPlatform

final class MacClippyOCRSchedulePolicyTests: XCTestCase {
    func testCapsRemainTwoConcurrentEightJobsAnd64MB() {
        XCTAssertEqual(MacClippyOCRSchedulePolicy.maxConcurrentRecognizers, 2)
        XCTAssertEqual(MacClippyOCRSchedulePolicy.maxPendingJobs, 8)
        XCTAssertEqual(MacClippyOCRSchedulePolicy.maxPendingBytes, 64 * 1024 * 1024)
    }

    func testRecognitionStartsOnlyWhenIdleAndNotOnLowPower() {
        XCTAssertFalse(
            MacClippyOCRSchedulePolicy.shouldStartRecognition(
                secondsSinceLastInput: 0.1,
                isLowPowerMode: false
            )
        )
        XCTAssertFalse(
            MacClippyOCRSchedulePolicy.shouldStartRecognition(
                secondsSinceLastInput: 30,
                isLowPowerMode: true
            )
        )
        XCTAssertTrue(
            MacClippyOCRSchedulePolicy.shouldStartRecognition(
                secondsSinceLastInput: MacClippyOCRSchedulePolicy.idleThreshold,
                isLowPowerMode: false
            )
        )
    }

    func testHugeImagesAreClampedTo2048BeforeRecognition() {
        XCTAssertEqual(MacClippyOCRSchedulePolicy.recognitionMaxPixelSize, 2_048)
        XCTAssertEqual(
            MacClippyOCRSchedulePolicy.recognitionPixelLimit(sourceMaxPixelSize: 8_000),
            2_048
        )
        XCTAssertEqual(
            MacClippyOCRSchedulePolicy.recognitionPixelLimit(sourceMaxPixelSize: 800),
            800
        )
        XCTAssertEqual(
            MacClippyOCRService.maxImagePixelSize,
            MacClippyOCRSchedulePolicy.recognitionMaxPixelSize
        )
    }
}
