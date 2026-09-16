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
        fputs("==> [MacClippyTestWait] until called (timeout=\(timeout))\n", stderr)
        MacClippyMainHop.setCaptureForTesting(true)
        defer {
            MacClippyMainHop.flushCapturedWork()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var iteration = 0
        while Date() < deadline {
            iteration += 1
            MacClippyMainHop.flushCapturedWork()
            if condition() {
                fputs("==> [MacClippyTestWait] condition matched (iteration=\(iteration))\n", stderr)
                Thread.sleep(forTimeInterval: 0.002)
                MacClippyMainHop.flushCapturedWork()
                return
            }
            Thread.sleep(forTimeInterval: 0.005)
            MacClippyMainHop.flushCapturedWork()
        }
        fputs("==> [MacClippyTestWait] timed out after \(iteration) iterations\n", stderr)
        MacClippyMainHop.flushCapturedWork()
        if failOnTimeout, !condition() {
            XCTFail("Timed out waiting for condition", file: file, line: line)
        }
    }
}
