import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class MacClippySnippetSpaceExpansionTests: XCTestCase {
    func testOutlookRemainsLiteralUntilSpaceThenExpandsExactlyOnce() {
        let focus = focusedContext()
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder)
        expander.startForTesting()
        defer { expander.stop() }

        typeCharacters(";outlook", on: expander)
        expander.expansionQueue.sync {}
        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
        XCTAssertFalse(expander.processKeyForTesting(.init(text: " ", keyCode: UInt16(kVK_Space))))
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 9)
        XCTAssertEqual(recorder.pasteCount, 1)
        XCTAssertEqual(recorder.postedKeyProcessIdentifiers, Array(repeating: 101, count: 9))
        XCTAssertFalse(expander.processKeyForTesting(.init(text: " ", keyCode: UInt16(kVK_Space))))
        expander.expansionQueue.sync {}
        XCTAssertEqual(recorder.pasteCount, 1)
    }

    func testCaretMayCatchUpAfterSpaceIsPassedToTheRecipient() {
        let focus = focusedContext()
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder)
        expander.startForTesting()
        defer { expander.stop() }
        let releaseQueue = blockExpansionQueue(expander)

        typeCharacters(";outlook ", on: expander)
        focus.setCurrentSelectionWithoutNotification(location: 8)
        focus.onCurrentContextRead { _, context in
            if context.selection?.location == 8 {
                focus.setCurrentSelectionWithoutNotification(location: 9)
            }
        }
        releaseQueue.signal()
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 9)
        XCTAssertEqual(recorder.pasteCount, 1)
    }

    func testFocusChangeWhileCaretIsCatchingUpCancelsExpansion() {
        let focus = focusedContext()
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder)
        expander.startForTesting()
        defer { expander.stop() }
        let releaseQueue = blockExpansionQueue(expander)

        typeCharacters(";outlook ", on: expander)
        focus.setCurrentSelectionWithoutNotification(location: 8)
        focus.onCurrentContextRead { _, _ in
            focus.setIdentity(MacClippySnippetFocusIdentity(processIdentifier: 202, elementIdentity: 2))
        }
        releaseQueue.signal()
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
    }

    func testFurtherTypingCancelsPendingSpaceExpansion() {
        let focus = focusedContext()
        let recorder = ExpansionRecorder()
        let blocker = ClipboardReadBlocker()
        let expander = makeExpander(focus: focus, recorder: recorder, clipboardTextProvider: blocker.read)
        expander.startForTesting()
        defer {
            blocker.release()
            expander.stop()
        }

        typeCharacters(";outlook ", on: expander)
        blocker.waitUntilStarted()
        XCTAssertFalse(expander.processKeyForTesting(.init(text: "x")))
        blocker.release()
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
    }

    func testShiftDoesNotPreventAnUppercaseTriggerFromExpanding() {
        let focus = focusedContext()
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder, trigger: ";Outlook")
        expander.startForTesting()
        defer { expander.stop() }

        let source = CGEventSource(stateID: .combinedSessionState)!
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_O), keyDown: true)!
        let units = Array(";Outlook".utf16)
        units.withUnsafeBufferPointer {
            event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress!)
        }
        event.flags = .maskShift
        XCTAssertNotNil(expander.handle(type: .keyDown, event: event))
        XCTAssertFalse(expander.processKeyForTesting(.init(text: " ", keyCode: UInt16(kVK_Space))))
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 9)
        XCTAssertEqual(recorder.pasteCount, 1)
    }

    private func focusedContext() -> SyntheticFocusContext {
        let focus = SyntheticFocusContext()
        focus.setIdentity(MacClippySnippetFocusIdentity(processIdentifier: 101, elementIdentity: 1))
        return focus
    }

    private func typeCharacters(_ text: String, on expander: MacClippySnippetExpander) {
        for character in text {
            XCTAssertFalse(expander.processKeyForTesting(.init(text: String(character))))
        }
    }

    private func blockExpansionQueue(_ expander: MacClippySnippetExpander) -> DispatchSemaphore {
        let enteredQueue = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        expander.expansionQueue.async {
            enteredQueue.signal()
            _ = releaseQueue.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(enteredQueue.wait(timeout: .now() + 2), .success)
        return releaseQueue
    }

    private func makeExpander(
        focus: SyntheticFocusContext,
        recorder: ExpansionRecorder,
        trigger: String = ";outlook",
        clipboardTextProvider: @escaping () -> String? = { nil }
    ) -> MacClippySnippetExpander {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippySpaceSnippet-\(UUID().uuidString)"))
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in recorder.recordPaste() },
            postEventsToProcess: { _, _, processIdentifier in
                recorder.recordPaste(processIdentifier: processIdentifier)
            }
        )
        let keyPoster = MacClippySnippetKeyPoster(
            postEvents: { keyDown, _, tap in
                recorder.recordKey(UInt16(keyDown.getIntegerValueField(.keyboardEventKeycode)), tap: tap)
            },
            postEventsToProcess: { keyDown, _, processIdentifier in
                recorder.recordKey(
                    UInt16(keyDown.getIntegerValueField(.keyboardEventKeycode)),
                    tap: .cgAnnotatedSessionEventTap,
                    processIdentifier: processIdentifier
                )
            }
        )
        return MacClippySnippetExpander(
            modeProvider: { .autoExpand },
            lookup: { $0 == trigger ? "expanded@example.test" : nil },
            injector: injector,
            keyPoster: keyPoster,
            focusContext: focus,
            clipboardTextProvider: clipboardTextProvider,
            expansionDidFinish: { recorder.recordFinish() }
        )
    }
}
