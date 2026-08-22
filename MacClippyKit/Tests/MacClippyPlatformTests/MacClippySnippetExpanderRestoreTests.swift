import Carbon.HIToolbox
import CoreGraphics
import XCTest

import MacClippyPlatform

final class MacClippySnippetExpanderRestoreTests: XCTestCase {
    private struct PostedKey {
        let keyCode: UInt16
        let tap: CGEventTapLocation
    }

    func testRestoresSuppressedDelimiterWhenAutomaticInjectionFails() {
        var postedKeys: [PostedKey] = []
        var pasteEventCount = 0
        let expander = expander(
            postedKeys: { postedKeys.append($0) },
            onPasteEvents: { pasteEventCount += 1 }
        )
        let plan = MacClippySnippetExpansionPlan(
            body: "replacement",
            charactersToDelete: 6,
            suppressCurrentEvent: true,
            suppressedDelimiterKeyCode: UInt16(kVK_Space)
        )

        expander.expandForTesting(using: plan)

        XCTAssertTrue(postedKeys.contains { $0.keyCode == UInt16(kVK_Space) })
        XCTAssertFalse(postedKeys.contains { $0.keyCode == UInt16(kVK_Delete) })
        XCTAssertEqual(pasteEventCount, 0)
    }

    func testRestoresSuppressedReturnWhenAutomaticInjectionFails() {
        var postedKeys: [PostedKey] = []
        let expander = expander(postedKeys: { postedKeys.append($0) })
        let plan = MacClippySnippetExpansionPlan(
            body: "replacement",
            charactersToDelete: 6,
            suppressCurrentEvent: true,
            suppressedDelimiterKeyCode: UInt16(kVK_Return)
        )

        expander.expandForTesting(using: plan)

        XCTAssertTrue(postedKeys.contains { $0.keyCode == UInt16(kVK_Return) })
    }

    func testExpanderKeysAreNotPostedIntoTheSessionTap() {
        var postedKeys: [PostedKey] = []
        let expander = expander(postedKeys: { postedKeys.append($0) })
        let plan = MacClippySnippetExpansionPlan(
            body: "replacement",
            charactersToDelete: 6,
            suppressCurrentEvent: true,
            suppressedDelimiterKeyCode: UInt16(kVK_Space)
        )

        expander.expandForTesting(using: plan)

        XCTAssertFalse(postedKeys.isEmpty)
        // Trigger deletes and the restored delimiter must bypass the
        // `.cgSessionEventTap` that drives trigger detection.
        for posted in postedKeys {
            XCTAssertEqual(posted.tap, .cgAnnotatedSessionEventTap, "key \(posted.keyCode) fed back into the tap")
        }
        XCTAssertEqual(MacClippySnippetKeyPoster.tapLocation, .cgAnnotatedSessionEventTap)
    }

    private func expander(
        postedKeys: @escaping (PostedKey) -> Void,
        onPasteEvents: @escaping () -> Void = {}
    ) -> MacClippySnippetExpander {
        let injector = MacClippyPasteInjector(
            pasteboard: NSPasteboard(name: NSPasteboard.Name("MacClippySnippetRestore-\(UUID().uuidString)")),
            isProcessTrusted: { false },
            postEvents: { _, _ in onPasteEvents() }
        )
        return MacClippySnippetExpander(
            modeProvider: { .autoExpand },
            lookup: { _ in "replacement" },
            injector: injector,
            keyPoster: MacClippySnippetKeyPoster(postEvents: { keyDown, _, tap in
                postedKeys(PostedKey(
                    keyCode: UInt16(keyDown.getIntegerValueField(.keyboardEventKeycode)),
                    tap: tap
                ))
            })
        )
    }
}
