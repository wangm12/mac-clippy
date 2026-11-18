import AppKit
import MacClippyPlatform
import XCTest

extension MacClippyPasteInjectorTests {
    func testExplicitProcessTargetUsesInjectedPosterInsteadOfGlobalPoster() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyTargetedPaste-\(UUID().uuidString)"))
        var globalPostCount = 0
        var targetedProcessIdentifier: Int32?
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in globalPostCount += 1 },
            postEventsToProcess: { _, _, processIdentifier in
                targetedProcessIdentifier = processIdentifier
            }
        )

        XCTAssertEqual(
            injector.inject(text: "isolated payload", targetProcessIdentifier: Int32(getpid())),
            .injected
        )
        XCTAssertEqual(targetedProcessIdentifier, Int32(getpid()))
        XCTAssertEqual(globalPostCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "isolated payload")
    }

    func testInjectPostsWillAndDidAroundPasteEvents() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPasteInjectNotifications-\(UUID().uuidString)"))
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var order: [String] = []
        let center = NotificationCenter.default
        let will = center.addObserver(forName: .macClippyWillInjectPasteKeystroke, object: nil, queue: nil) { _ in
            order.append("will")
        }
        let did = center.addObserver(forName: .macClippyDidInjectPasteKeystroke, object: nil, queue: nil) { _ in
            order.append("did")
        }
        defer {
            center.removeObserver(will)
            center.removeObserver(did)
        }
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in order.append("paste") }
        )

        XCTAssertEqual(injector.inject(text: "replacement"), .injected)
        XCTAssertEqual(order, ["will", "paste", "did"])
    }
}
