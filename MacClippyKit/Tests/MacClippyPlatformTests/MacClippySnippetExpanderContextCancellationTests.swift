import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class SnippetExpanderContextTests: XCTestCase {
    func testEscapeCancelsQueuedPlanWithoutRepostingPassedDelimiter() {
        let blocker = ClipboardReadBlocker()
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder, clipboardTextProvider: blocker.read)
        expander.startForTesting()
        defer { expander.stop() }

        typeTriggerAndDelimiter(on: expander)
        blocker.waitUntilStarted()
        XCTAssertFalse(expander.processKeyForTesting(.init(text: "", keyCode: UInt16(kVK_Escape))))
        blocker.release()
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
        XCTAssertEqual(recorder.postedKeys.filter { $0 == UInt16(kVK_Space) }.count, 0)
    }

    func testConfirmWithTabFocusChangeDropsSuppressedTabFailClosed() {
        let blocker = ClipboardReadBlocker()
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(
            focus: focus,
            recorder: recorder,
            mode: .confirmWithTab,
            clipboardTextProvider: blocker.read
        )
        expander.startForTesting()
        defer {
            blocker.release()
            expander.stop()
        }

        for character in ";email" {
            XCTAssertFalse(expander.processKeyForTesting(.init(text: String(character))))
        }
        XCTAssertTrue(expander.processKeyForTesting(.init(text: "\t", keyCode: UInt16(kVK_Tab))))
        blocker.waitUntilStarted()
        focus.setIdentity(identity(pid: 202, element: 2))
        blocker.release()
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
        XCTAssertFalse(recorder.postedKeys.contains(UInt16(kVK_Tab)))
    }

    func testCrossApplicationChangeCancelsQueuedExpansion() {
        let blocker = ClipboardReadBlocker()
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder, clipboardTextProvider: blocker.read)
        expander.startForTesting()
        defer { expander.stop() }

        typeTriggerAndDelimiter(on: expander)
        blocker.waitUntilStarted()
        focus.setIdentity(identity(pid: 202, element: 2))
        blocker.release()
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
        XCTAssertFalse(recorder.postedKeys.contains(UInt16(kVK_Space)))
    }

    func testSameApplicationFocusChangeCancelsQueuedExpansion() {
        let blocker = ClipboardReadBlocker()
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder, clipboardTextProvider: blocker.read)
        expander.startForTesting()
        defer { expander.stop() }

        typeTriggerAndDelimiter(on: expander)
        blocker.waitUntilStarted()
        focus.setIdentity(identity(pid: 101, element: 2))
        blocker.release()
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
        XCTAssertFalse(recorder.postedKeys.contains(UInt16(kVK_Space)))
    }

    func testSelectionChangeWithinSameElementCancelsQueuedExpansion() {
        let blocker = ClipboardReadBlocker()
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder, clipboardTextProvider: blocker.read)
        expander.startForTesting()
        defer { expander.stop() }

        typeTriggerAndDelimiter(on: expander)
        blocker.waitUntilStarted()
        focus.setCurrentSelectionWithoutNotification(location: 8)
        blocker.release()
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
    }

    func testSelectionChangeBeforeExpansionWorkerStartsCancelsQueuedExpansion() {
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let providerCalled = DispatchSemaphore(value: 0)
        let expander = makeExpander(
            focus: focus,
            recorder: recorder,
            clipboardTextProvider: {
                providerCalled.signal()
                return nil
            }
        )
        expander.startForTesting()
        defer { expander.stop() }

        let queueEntered = DispatchSemaphore(value: 0)
        let releaseQueue = DispatchSemaphore(value: 0)
        expander.expansionQueue.async {
            queueEntered.signal()
            _ = releaseQueue.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(queueEntered.wait(timeout: .now() + 2), .success)

        typeTriggerAndDelimiter(on: expander)
        focus.setCurrentSelectionWithoutNotification(location: 8)
        releaseQueue.signal()
        recorder.waitUntilFinished()

        XCTAssertEqual(providerCalled.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
    }

    func testMouseTransitionInvalidatesQueuedPlan() {
        let blocker = ClipboardReadBlocker()
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder, clipboardTextProvider: blocker.read)
        expander.startForTesting()
        defer { expander.stop() }

        typeTriggerAndDelimiter(on: expander)
        blocker.waitUntilStarted()
        expander.processMouseDownForTesting()
        focus.setIdentity(identity(pid: 101, element: 2))
        blocker.release()
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
        XCTAssertFalse(recorder.postedKeys.contains(UInt16(kVK_Space)))
    }

    func testAtoBtoAFocusSequenceDoesNotReplayOldGeneration() {
        let blocker = ClipboardReadBlocker()
        let focus = SyntheticFocusContext()
        let original = identity(pid: 101, element: 1)
        focus.setIdentity(original)
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder, clipboardTextProvider: blocker.read)
        expander.startForTesting()
        defer { expander.stop() }

        typeTriggerAndDelimiter(on: expander)
        blocker.waitUntilStarted()
        focus.setIdentity(identity(pid: 202, element: 2))
        focus.setIdentity(original)
        blocker.release()
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
    }

    func testFurtherTypingCancelsPlanAfterNaturallyPassingDelimiter() {
        let blocker = ClipboardReadBlocker()
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder, clipboardTextProvider: blocker.read)
        expander.startForTesting()
        defer { expander.stop() }

        typeTriggerAndDelimiter(on: expander)
        blocker.waitUntilStarted()
        XCTAssertFalse(expander.processKeyForTesting(.init(text: "x", keyCode: 7)))
        blocker.release()
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
        XCTAssertEqual(recorder.postedKeys.filter { $0 == UInt16(kVK_Space) }.count, 0)
    }

    private func makeExpander(
        focus: SyntheticFocusContext,
        recorder: ExpansionRecorder,
        mode: MacClippySnippetExpansionMode = .autoExpand,
        clipboardTextProvider: @escaping () -> String? = { nil }
    ) -> MacClippySnippetExpander {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippySnippetContext-\(UUID().uuidString)"))
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in recorder.recordPaste() },
            postEventsToProcess: { _, _, processIdentifier in
                recorder.recordPaste(processIdentifier: processIdentifier)
            }
        )
        return MacClippySnippetExpander(
            modeProvider: { mode },
            lookup: { $0 == ";email" ? "expanded@example.test" : nil },
            injector: injector,
            keyPoster: MacClippySnippetKeyPoster(postEvents: { keyDown, _, tap in
                recorder.recordKey(
                    UInt16(keyDown.getIntegerValueField(.keyboardEventKeycode)),
                    tap: tap
                )
            }, postEventsToProcess: { keyDown, _, processIdentifier in
                recorder.recordKey(
                    UInt16(keyDown.getIntegerValueField(.keyboardEventKeycode)),
                    tap: .cgAnnotatedSessionEventTap,
                    processIdentifier: processIdentifier
                )
            }, postEventToProcess: { event, processIdentifier in
                recorder.recordKey(
                    UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                    tap: .cgAnnotatedSessionEventTap,
                    processIdentifier: processIdentifier
                )
            }),
            focusContext: focus,
            clipboardTextProvider: clipboardTextProvider,
            expansionDidFinish: { recorder.recordFinish() }
        )
    }

    private func typeTriggerAndDelimiter(on expander: MacClippySnippetExpander) {
        for character in ";email" {
            XCTAssertFalse(expander.processKeyForTesting(.init(text: String(character))))
        }
        XCTAssertFalse(expander.processKeyForTesting(.init(text: " ", keyCode: UInt16(kVK_Space))))
    }

    private func identity(pid: Int32, element: UInt64) -> MacClippySnippetFocusIdentity {
        MacClippySnippetFocusIdentity(processIdentifier: pid, elementIdentity: element)
    }

    private func unicodeKeyEvent(_ string: String) -> CGEvent {
        unicodeKeyEvent(Array(string.utf16))
    }

    private func unicodeKeyEvent(_ units: [UniChar]) -> CGEvent {
        let source = CGEventSource(stateID: .combinedSessionState)!
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Space), keyDown: true)!
        units.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress!
            )
        }
        return event
    }
}

extension SnippetExpanderContextTests {
    func testFastLeadingCJKAndEmojiTextAdvancesTriggerCaretAnchor() {
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder)
        expander.startForTesting()
        defer { expander.stop() }

        for character in "A先😃;email " {
            XCTAssertFalse(expander.processKeyForTesting(.init(text: String(character))))
        }
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 7)
        XCTAssertEqual(recorder.pasteCount, 1)
        XCTAssertEqual(recorder.pasteProcessIdentifiers, [101])
        XCTAssertEqual(focus.currentContext()?.selection, MacClippySnippetTextSelection(location: 11, length: 0))
    }

    func testSingleProductionKeyEventKeepsEmojiAndOffsetsTriggerWithinPayload() {
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder)
        expander.startForTesting()
        defer { expander.stop() }

        let event = unicodeKeyEvent("A先😃;email ")
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 101)
        let result = expander.handle(type: .keyDown, event: event)
        XCTAssertNotNil(result, "auto expansion passes the delimiter event through")
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 7)
        XCTAssertEqual(recorder.pasteCount, 1)
        XCTAssertEqual(recorder.postedKeyProcessIdentifiers, Array(repeating: 101, count: 7))
        XCTAssertEqual(recorder.pasteProcessIdentifiers, [101])
        XCTAssertEqual(focus.currentContext()?.selection, MacClippySnippetTextSelection(location: 11, length: 0))
    }

    func testMalformedSurrogateIsIgnoredAtProductionEventBoundary() {
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder)
        expander.startForTesting()
        defer { expander.stop() }

        let event = unicodeKeyEvent([0x0041, 0xD800, 0x003B, 0x0065, 0x006D, 0x0061, 0x0069, 0x006C, 0x0020])
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 101)
        _ = expander.handle(type: .keyDown, event: event)
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 7)
        XCTAssertEqual(recorder.pasteCount, 1)
        XCTAssertEqual(focus.currentContext()?.selection, MacClippySnippetTextSelection(location: 8, length: 0))
    }

    func testProductionFocusMonitorAdvancesCollapsedCaretByUTF16InputLength() {
        let expectedIdentity = identity(pid: 101, element: 1)
        let monitor = MacClippySnippetFocusContextMonitor(
            initialContext: MacClippySnippetFocusContext(
                identity: expectedIdentity,
                selection: MacClippySnippetTextSelection(location: 4, length: 0)
            )
        )

        monitor.noteInputText("A先😃")

        XCTAssertEqual(monitor.cachedIdentity, expectedIdentity)
        XCTAssertEqual(monitor.cachedSelection, MacClippySnippetTextSelection(location: 8, length: 0))
        monitor.noteInputText("")
        XCTAssertNil(monitor.cachedSelection, "non-text editing input must require a fresh caret sample")
    }
}
