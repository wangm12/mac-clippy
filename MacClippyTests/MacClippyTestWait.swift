import AppKit
import QuartzCore
import XCTest

@testable import MacClippy

enum MacClippyTestWait {
    static func until(
        _ condition: () -> Bool,
        timeout: TimeInterval = 2.0,
        failOnTimeout: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        MacClippyMainHop.setCaptureForTesting(true)
        defer {
            MacClippyMainHop.flushCapturedWork()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            MacClippyMainHop.flushCapturedWork()
            if condition() {
                Thread.sleep(forTimeInterval: 0.002)
                MacClippyMainHop.flushCapturedWork()
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
            MacClippyMainHop.flushCapturedWork()
        }
        MacClippyMainHop.flushCapturedWork()
        if failOnTimeout, !condition() {
            XCTFail("Timed out waiting for condition", file: file, line: line)
        }
    }
}
