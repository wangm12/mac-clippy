import AppKit
import Foundation
import XCTest

import MacClippyPlatformTestObjCSupport
@testable import MacClippyPlatform

final class MacClippyRecoveryGenerationTests: XCTestCase {
    func testRecoveryCompletionReportsGenerationMaterializedAfterPollEntryAdvanced() {
        let pasteboard = MacClippyMakeMalformedPasteboard(0)
        let sourceLookup = AdvancingSourceAppLookup(pasteboard: pasteboard)
        let reader = MacClippySystemPasteboardReader(
            pasteboard: pasteboard,
            sourceAppBundleID: { sourceLookup.lookup() }
        )
        let observer = PasteboardObserver(
            reader: reader,
            pollInterval: 60,
            queue: DispatchQueue(label: "MacClippyRecoveryGenerationTests.\(UUID().uuidString)"),
            secondsSinceLastUserInput: { 0 }
        )
        observer.disableAutomaticPollingForTesting()

        var delivered: [Int] = []
        observer.start { delivered.append($0.changeCount) }
        observer.poll()

        let completed = expectation(description: "recovery read completes once")
        var completions: [Int?] = []
        observer.requestCurrentGenerationRead { changeCount in
            completions.append(changeCount)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)

        XCTAssertEqual(sourceLookup.advanceCount, 1)
        XCTAssertEqual(delivered, [20])
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions.first!, 20, "completion names the materialized generation, not poll-entry 19")

        MacClippySetSyntheticPasteboardContents(pasteboard, 21, "external after recovery")
        observer.poll()
        XCTAssertEqual(delivered, [20, 21], "a genuinely newer external generation remains observable")

        observer.stop()
        observer.poll()
    }
}

private final class AdvancingSourceAppLookup {
    private let pasteboard: NSPasteboard
    private(set) var advanceCount = 0

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    func lookup() -> String? {
        guard advanceCount == 0 else { return nil }
        advanceCount = 1
        MacClippySetSyntheticPasteboardContents(pasteboard, 20, "newly materialized generation")
        return nil
    }
}
