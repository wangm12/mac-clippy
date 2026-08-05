import XCTest

import MacClippyCore
import MacClippyPlatform

final class MacClippySnippetLookupSnapshotTests: XCTestCase {
    func testSnapshotReplacesTriggersAndSkipsBlankTriggers() {
        let snapshot = MacClippySnippetLookupSnapshot()
        let first = Snippet(name: "First", body: "one", trigger: ";one")
        let second = Snippet(name: "Second", body: "two", trigger: " ;two ")
        let blank = Snippet(name: "Blank", body: "ignored", trigger: "   ")

        snapshot.replace(with: [first, second, blank])

        XCTAssertEqual(snapshot.body(for: ";one"), "one")
        XCTAssertEqual(snapshot.body(for: ";two"), "two")
        XCTAssertNil(snapshot.body(for: "   "))

        snapshot.replace(with: [second])
        XCTAssertNil(snapshot.body(for: ";one"))
        XCTAssertEqual(snapshot.body(for: ";two"), "two")
    }
}
