import Foundation
import XCTest

import MacClippyPlatform

final class MacClippyOCRServiceTests: XCTestCase {
    func testInvalidImageDataThrowsInvalidImage() async {
        do {
            _ = try await MacClippyOCRService().recognize(data: Data([0x01, 0x02, 0x03]))
            XCTFail("Expected invalid image error")
        } catch let error as MacClippyOCRError {
            XCTAssertEqual(error, .invalidImage)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
