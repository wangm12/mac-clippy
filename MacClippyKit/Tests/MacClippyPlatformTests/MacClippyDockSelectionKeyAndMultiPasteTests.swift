import AppKit
import Foundation
import XCTest

import MacClippyCore
import MacClippyPlatform

final class MacClippyDockMultiPastePolicyTests: XCTestCase {
    private struct SyntheticStorageError: Error {}

    private func id() -> RecordID { RecordID.generate() }

    func testTextCompatibleKindsAreTextHtmlRtfOnly() {
        XCTAssertTrue(MacClippyDockMultiPastePolicy.isTextCompatible(.text))
        XCTAssertTrue(MacClippyDockMultiPastePolicy.isTextCompatible(.html))
        XCTAssertTrue(MacClippyDockMultiPastePolicy.isTextCompatible(.rtf))
        XCTAssertFalse(MacClippyDockMultiPastePolicy.isTextCompatible(.image))
        XCTAssertFalse(MacClippyDockMultiPastePolicy.isTextCompatible(.files))
        XCTAssertFalse(MacClippyDockMultiPastePolicy.isTextCompatible(.unsupported))
    }

    func testHomogeneousTextSelectionMergesInVisualOrderWithNewlineDelimiter() {
        let a = id()
        let b = id()
        let c = id()
        // Visual order in the dock: c, a, b (newest first). The merged paste
        // must follow what the user sees, not an arbitrary Set order.
        let ordered = [c, a, b]
        let texts = [c: "third", a: "first", b: "second"]

        let result = MacClippyDockMultiPastePolicy.resolve(
            orderedSelectedIDs: ordered,
            kindForID: { _ in .text },
            textForID: { texts[$0] }
        )

        XCTAssertEqual(result, .mergedText("third\nfirst\nsecond"))
    }

    func testHomogeneousHtmlSelectionMergesPlainText() {
        let a = id()
        let b = id()
        let result = MacClippyDockMultiPastePolicy.resolve(
            orderedSelectedIDs: [a, b],
            kindForID: { _ in .html },
            textForID: { $0 == a ? "<b>one</b>" : "two" }
        )
        XCTAssertEqual(result, .mergedText("<b>one</b>\ntwo"))
    }

    func testMixedSelectionReportsSupportedAndUnsupportedWithoutMergedPayload() {
        let text1 = id()
        let image1 = id()
        let files1 = id()
        let text2 = id()
        let ordered = [text1, image1, files1, text2]

        let result = MacClippyDockMultiPastePolicy.resolve(
            orderedSelectedIDs: ordered,
            kindForID: { id in
                switch id {
                case text1, text2: .text
                case image1: .image
                case files1: .files
                default: .unsupported
                }
            },
            textForID: { _ in "x" }
        )

        guard case let .mixed(supported, unsupported, kinds) = result else {
            XCTFail("expected .mixed for a mixed selection")
            return
        }
        XCTAssertEqual(supported, [text1, text2])
        XCTAssertEqual(unsupported, [image1, files1])
        XCTAssertEqual(kinds, [.image, .files])
    }

    func testEmptySelectionReturnsEmptyMixed() {
        let result = MacClippyDockMultiPastePolicy.resolve(
            orderedSelectedIDs: [],
            kindForID: { _ in .text },
            textForID: { _ in nil }
        )
        XCTAssertEqual(result, .mixed(supportedIDs: [], unsupportedIDs: [], unsupportedKinds: []))
    }

    func testEmptyRealTextIsAVaidEmptyPieceAndIsMerged() {
        let a = id()
        let b = id()
        // a has text, b has an EMPTY STRING payload (a real decoded empty
        // text, e.g. an empty captured text marker). Empty real text is a
        // valid empty piece and is merged in visual order so nothing is
        // silently dropped.
        let result = MacClippyDockMultiPastePolicy.resolve(
            orderedSelectedIDs: [a, b],
            kindForID: { _ in .text },
            textForID: { $0 == a ? "hello" : "" }
        )
        XCTAssertEqual(result, .mergedText("hello\n"))
    }

    func testTextCompatibleWithUnavailableTextIsReportedAndNoPasteOccurs() {
        let a = id()
        let b = id()
        // a has decodable text, b has a nil payload (e.g. malformed RTF whose
        // NSAttributedString could not be initialized). The policy must NOT
        // merge b as an empty piece — that would be silent data loss. It must
        // report b as unavailable with its Kind, and NO paste occurs for the
        // selection (no .mergedText result).
        let result = MacClippyDockMultiPastePolicy.resolve(
            orderedSelectedIDs: [a, b],
            kindForID: { _ in .rtf },
            textForID: { $0 == a ? "hello" : nil }
        )
        guard case let .textUnavailable(availableIDs, unavailableIDs, unavailableKinds) = result else {
            XCTFail("expected .textUnavailable when a text-compatible payload is unavailable, got \(result)")
            return
        }
        XCTAssertEqual(availableIDs, [a])
        XCTAssertEqual(unavailableIDs, [b])
        XCTAssertEqual(unavailableKinds, [.rtf])
    }

    func testTextUnavailableReportsPerIDKindInVisualOrder() {
        let a = id()
        let b = id()
        let c = id()
        // a (.text) decodes, b (.rtf) is unavailable, c (.html) decodes. The
        // unavailable ID and its kind are reported in visual order; the two
        // available IDs are listed so the caller can confirm exactly which
        // records were not pasted.
        let result = MacClippyDockMultiPastePolicy.resolve(
            orderedSelectedIDs: [a, b, c],
            kindForID: { id in
                switch id {
                case a: .text
                case b: .rtf
                case c: .html
                default: .unsupported
                }
            },
            textForID: { id in
                switch id {
                case a: "a"
                case b: nil
                case c: "c"
                default: nil
                }
            }
        )
        guard case let .textUnavailable(availableIDs, unavailableIDs, unavailableKinds) = result else {
            XCTFail("expected .textUnavailable, got \(result)")
            return
        }
        XCTAssertEqual(availableIDs, [a, c])
        XCTAssertEqual(unavailableIDs, [b])
        XCTAssertEqual(unavailableKinds, [.rtf])
    }

    func testUnsupportedKindTakesPrecedenceOverUnavailableText() {
        let a = id()
        let b = id()
        let image = id()
        // a decodes, b is an unavailable text payload, image is an unsupported
        // kind. A mixed selection never pastes a subset; the unsupported kind
        // is reported first (.mixed) so the user is told about the kind
        // mismatch before the undecodable payload.
        let result = MacClippyDockMultiPastePolicy.resolve(
            orderedSelectedIDs: [a, b, image],
            kindForID: { id in
                switch id {
                case a, b: .rtf
                case image: .image
                default: .unsupported
                }
            },
            textForID: { id in
                switch id {
                case a: "a"
                case b: nil
                case image: nil
                default: nil
                }
            }
        )
        guard case let .mixed(supportedIDs, unsupportedIDs, unsupportedKinds) = result else {
            XCTFail("expected .mixed when an unsupported kind is present with unavailable text, got \(result)")
            return
        }
        XCTAssertEqual(supportedIDs, [a, b])
        XCTAssertEqual(unsupportedIDs, [image])
        XCTAssertEqual(unsupportedKinds, [.image])
    }

    func testUnsupportedKindIsReportedNotDropped() {
        let a = id()
        let b = id()
        let result = MacClippyDockMultiPastePolicy.resolve(
            orderedSelectedIDs: [a, b],
            kindForID: { $0 == a ? .text : .unsupported },
            textForID: { _ in "x" }
        )
        guard case let .mixed(supported, unsupported, kinds) = result else {
            XCTFail("expected .mixed when an unsupported kind is present")
            return
        }
        XCTAssertEqual(supported, [a])
        XCTAssertEqual(unsupported, [b])
        XCTAssertEqual(kinds, [.unsupported])
    }

    func testKindMappingCoversEveryContentKind() {
        XCTAssertEqual(MacClippyDockMultiPasteKindMapping.kind(for: .text), .text)
        XCTAssertEqual(MacClippyDockMultiPasteKindMapping.kind(for: .html), .html)
        XCTAssertEqual(MacClippyDockMultiPasteKindMapping.kind(for: .rtf), .rtf)
        XCTAssertEqual(MacClippyDockMultiPasteKindMapping.kind(for: .image), .image)
        XCTAssertEqual(MacClippyDockMultiPasteKindMapping.kind(for: .files), .files)
    }

    func testThrowingResolutionPropagatesInfrastructureFailure() {
        let record = id()

        XCTAssertThrowsError(
            try MacClippyDockMultiPastePolicy.resolveThrowing(
                orderedSelectedIDs: [record],
                kindForID: { _ in .text },
                textForID: { _ in throw SyntheticStorageError() }
            )
        ) { error in
            XCTAssertTrue(error is SyntheticStorageError)
        }
    }
}

final class MacClippyDockSelectionClickPolicyTests: XCTestCase {
    private func decision(
        clickCount: Int,
        modifiers: NSEvent.ModifierFlags = []
    ) -> MacClippyDockSelectionClickPolicy.Action {
        MacClippyDockSelectionClickPolicy.decision(clickCount: clickCount, modifiers: modifiers)
    }

    func testPlainSingleClickFocuses() {
        XCTAssertEqual(decision(clickCount: 1), .focus)
    }

    func testPlainDoubleClickCopies() {
        XCTAssertEqual(decision(clickCount: 2), .copy)
    }

    func testTripleClickStillCopies() {
        XCTAssertEqual(decision(clickCount: 3), .copy)
    }

    func testCmdSingleClickToggles() {
        XCTAssertEqual(decision(clickCount: 1, modifiers: .command), .toggle)
    }

    func testShiftSingleClickExtendsRange() {
        XCTAssertEqual(decision(clickCount: 1, modifiers: .shift), .extendRange)
    }

    func testCmdShiftSingleClickToggles() {
        XCTAssertEqual(decision(clickCount: 1, modifiers: [.command, .shift]), .toggle)
    }

    // The critical P1 invariant: a double click is ALWAYS a copy regardless of
    // modifiers, so Cmd/Shift double-click never pastes and never toggles.
    func testModifiersNeverMakeDoubleClickPasteOrToggle() {
        XCTAssertEqual(decision(clickCount: 2, modifiers: .command), .copy)
        XCTAssertEqual(decision(clickCount: 2, modifiers: .shift), .copy)
        XCTAssertEqual(decision(clickCount: 2, modifiers: [.command, .shift]), .copy)
    }
}
