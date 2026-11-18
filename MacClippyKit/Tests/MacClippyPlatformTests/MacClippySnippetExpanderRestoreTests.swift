import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class MacClippySnippetExpanderRestoreTests: XCTestCase {
    func testMouseFocusChangeResetsACompletedTriggerBeforeNextDelimiter() {
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder)
        expander.startForTesting()
        defer { expander.stop() }

        typeCharacters(";email", on: expander)
        expander.processMouseDownForTesting()
        focus.setIdentity(identity(pid: 101, element: 2))
        let delimiterWasSuppressed = expander.processKeyForTesting(
            .init(text: " ", keyCode: UInt16(kVK_Space))
        )

        XCTAssertFalse(delimiterWasSuppressed)
        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
    }

    func testAccessibilityFocusMissingAtCommitFailsClosed() {
        let blocker = ClipboardReadBlocker()
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder, clipboardTextProvider: blocker.read)
        expander.startForTesting()
        defer { expander.stop() }

        typeTriggerAndDelimiter(on: expander)
        blocker.waitUntilStarted()
        focus.setCurrentIdentityWithoutNotification(nil)
        blocker.release()
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
        XCTAssertFalse(recorder.postedKeys.contains(UInt16(kVK_Space)))
    }

    func testStopAndRestartInvalidatesWorkFromEarlierLifecycle() {
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
        expander.stop()
        focus.setIdentity(original)
        expander.startForTesting()
        blocker.release()
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
    }

    func testStopDoesNotWaitForSlowClipboardProvider() {
        let blocker = ClipboardReadBlocker()
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder, clipboardTextProvider: blocker.read)
        expander.startForTesting()
        defer { expander.stop() }

        typeTriggerAndDelimiter(on: expander)
        blocker.waitUntilStarted()
        expander.stop()
        blocker.release()
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
    }

    func testUnavailableAccessibilityDoesNotSuppressDelimiterOrDeleteTrigger() {
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder, isTrusted: { false })
        expander.startForTesting()
        defer { expander.stop() }

        typeCharacters(";email", on: expander)
        let delimiterWasSuppressed = expander.processKeyForTesting(
            .init(text: " ", keyCode: UInt16(kVK_Space))
        )

        XCTAssertFalse(delimiterWasSuppressed)
        XCTAssertTrue(recorder.postedKeys.isEmpty)
        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
    }

    func testPreparationFailurePreservesClipboardAfterPassingDelimiter() {
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(
            focus: focus,
            recorder: recorder,
            preparer: { _, _ in false }
        )
        expander.startForTesting()
        defer { expander.stop() }

        typeTriggerAndDelimiter(on: expander)
        XCTAssertEqual(focus.cachedSelection, MacClippySnippetTextSelection(location: 7, length: 0))
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
        XCTAssertEqual(recorder.postedKeys.filter { $0 == UInt16(kVK_Space) }.count, 0)
    }

    func testSafeExpansionPostsOnlyAnnotatedDeleteKeys() {
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let expander = makeExpander(focus: focus, recorder: recorder)
        expander.startForTesting()
        defer { expander.stop() }

        typeTriggerAndDelimiter(on: expander)
        XCTAssertEqual(focus.cachedSelection, MacClippySnippetTextSelection(location: 7, length: 0))
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 7)
        XCTAssertEqual(recorder.pasteCount, 1)
        XCTAssertEqual(recorder.postedKeyProcessIdentifiers, Array(repeating: 101, count: 7))
        XCTAssertEqual(recorder.pasteProcessIdentifiers, [101])
        XCTAssertTrue(recorder.postedTaps.allSatisfy { $0 == .cgAnnotatedSessionEventTap })
    }

    private func makeExpander(
        focus: SyntheticFocusContext,
        recorder: ExpansionRecorder,
        mode: MacClippySnippetExpansionMode = .autoExpand,
        clipboardTextProvider: @escaping () -> String? = { nil },
        isTrusted: @escaping () -> Bool = { true },
        onDelete: (() -> Void)? = nil,
        postKeyEvents: MacClippySnippetKeyPoster.Post? = nil,
        pasteboard suppliedPasteboard: NSPasteboard? = nil,
        preparer: @escaping (MacClippyPasteboardContent, NSPasteboard) -> Bool = { content, pasteboard in
            MacClippyPasteboardPreparer.prepare(content, on: pasteboard)
        }
    ) -> MacClippySnippetExpander {
        let pasteboard = suppliedPasteboard ?? NSPasteboard(
            name: NSPasteboard.Name("MacClippySnippetSafety-\(UUID().uuidString)")
        )
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: isTrusted,
            postEvents: { _, _ in recorder.recordPaste() },
            postEventsToProcess: { _, _, processIdentifier in
                recorder.recordPaste(processIdentifier: processIdentifier)
            },
            preparer: preparer
        )
        return MacClippySnippetExpander(
            modeProvider: { mode },
            lookup: { $0 == ";email" ? "expanded@example.test" : nil },
            injector: injector,
            keyPoster: MacClippySnippetKeyPoster(postEvents: { keyDown, keyUp, tap in
                let keyCode = UInt16(keyDown.getIntegerValueField(.keyboardEventKeycode))
                if let postKeyEvents {
                    postKeyEvents(keyDown, keyUp, tap)
                } else {
                    recorder.recordKey(keyCode, tap: tap)
                }
                if keyCode == UInt16(kVK_Delete) {
                    onDelete?()
                }
            }, postEvent: { event, _ in
                recorder.recordInputEvent(event, processIdentifier: nil)
            }, postEventsToProcess: { keyDown, keyUp, processIdentifier in
                let keyCode = UInt16(keyDown.getIntegerValueField(.keyboardEventKeycode))
                if let postKeyEvents {
                    postKeyEvents(keyDown, keyUp, .cgAnnotatedSessionEventTap)
                } else {
                    recorder.recordKey(
                        keyCode,
                        tap: .cgAnnotatedSessionEventTap,
                        processIdentifier: processIdentifier
                    )
                }
                if keyCode == UInt16(kVK_Delete) {
                    onDelete?()
                }
            }, postEventToProcess: { event, processIdentifier in
                recorder.recordInputEvent(event, processIdentifier: processIdentifier)
            }),
            focusContext: focus,
            clipboardTextProvider: clipboardTextProvider,
            expansionDidFinish: { recorder.recordFinish() }
        )
    }

    private func typeTriggerAndDelimiter(on expander: MacClippySnippetExpander) {
        typeCharacters(";email", on: expander)
        XCTAssertFalse(expander.processKeyForTesting(.init(text: " ", keyCode: UInt16(kVK_Space))))
    }

    private func typeCharacters(_ string: String, on expander: MacClippySnippetExpander) {
        for character in string {
            XCTAssertFalse(expander.processKeyForTesting(.init(text: String(character))))
        }
    }

    private func identity(pid: Int32, element: UInt64) -> MacClippySnippetFocusIdentity {
        MacClippySnippetFocusIdentity(processIdentifier: pid, elementIdentity: element)
    }

    private func keyEvent(
        keyCode: UInt16,
        keyDown: Bool = true,
        flags: CGEventFlags = []
    ) -> CGEvent {
        let source = CGEventSource(stateID: .combinedSessionState)!
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)!
        event.flags = flags
        return event
    }

    private func flagsChangedEvent(keyCode: UInt16, flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(source: CGEventSource(stateID: .combinedSessionState))!
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        event.flags = flags
        return event
    }
}

extension MacClippySnippetExpanderRestoreTests {
    func testGateClosingAfterDeleteCommitStartsStillPostsMatchingPaste() {
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let gate = MacClippyPasteInjectionGate()
        let expander = makeExpander(
            focus: focus,
            recorder: recorder,
            onDelete: { if recorder.deleteCount == 1 { gate.close() } }
        )
        expander.currentGate = gate
        expander.startForTesting()
        defer { expander.stop() }

        typeTriggerAndDelimiter(on: expander)
        recorder.waitUntilFinished()

        XCTAssertEqual(recorder.deleteCount, 7, "the admitted trigger deletion must finish as a unit")
        XCTAssertEqual(recorder.pasteCount, 1, "the matching paste must complete after deletion begins")
        XCTAssertEqual(recorder.pasteProcessIdentifiers, [101])
    }

    func testExternalCopyDuringFinalFreshContextValidationIsNeverDeletedOrPastedOver() {
        let focus = SyntheticFocusContext()
        let expectedIdentity = identity(pid: 101, element: 1)
        focus.setIdentity(expectedIdentity)
        let recorder = ExpansionRecorder()
        let pasteboard = NSPasteboard.withUniqueName()
        XCTAssertTrue(pasteboard.setString("previous clipboard", forType: .string))
        let boundaryProbe = PreparedClipboardContextBoundaryProbe()
        focus.onCurrentContextRead { _, context in
            boundaryProbe.observe(context, expectedIdentity: expectedIdentity, pasteboard: pasteboard)
        }
        let expander = makeExpander(focus: focus, recorder: recorder, pasteboard: pasteboard)
        expander.startForTesting()
        defer { expander.stop() }

        typeTriggerAndDelimiter(on: expander)
        recorder.waitUntilFinished()

        let observed = boundaryProbe.snapshot
        XCTAssertTrue(observed.finalPreparedContextSeen)
        XCTAssertTrue(observed.externalCopyWriteSucceeded)
        XCTAssertEqual(observed.contextReadsAfterBoundary, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
        XCTAssertEqual(recorder.deleteCount, 0)
        XCTAssertEqual(recorder.pasteCount, 0)
    }
}

private struct PreparedClipboardContextBoundarySnapshot {
    let finalPreparedContextSeen: Bool
    let externalCopyWriteSucceeded: Bool
    let contextReadsAfterBoundary: Int
}

private final class PreparedClipboardContextBoundaryProbe {
    private let lock = NSLock()
    private var didSeeFinalPreparedContext = false
    private var didWriteExternalCopy = false
    private var readsAfterBoundary = 0

    var snapshot: PreparedClipboardContextBoundarySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return PreparedClipboardContextBoundarySnapshot(
            finalPreparedContextSeen: didSeeFinalPreparedContext,
            externalCopyWriteSucceeded: didWriteExternalCopy,
            contextReadsAfterBoundary: readsAfterBoundary
        )
    }

    func observe(
        _ context: MacClippySnippetFocusContext,
        expectedIdentity: MacClippySnippetFocusIdentity,
        pasteboard: NSPasteboard
    ) {
        lock.lock()
        guard !didSeeFinalPreparedContext else {
            readsAfterBoundary += 1
            lock.unlock()
            return
        }
        let clipboardWasPrepared = pasteboard.string(forType: .string) == "expanded@example.test"
        let contextWasCurrent = context.identity == expectedIdentity
            && context.selection == MacClippySnippetTextSelection(location: 7, length: 0)
        guard clipboardWasPrepared, contextWasCurrent else {
            lock.unlock()
            return
        }
        didSeeFinalPreparedContext = true
        lock.unlock()

        pasteboard.clearContents()
        let succeeded = pasteboard.setString("new user copy", forType: .string)
        lock.lock()
        didWriteExternalCopy = succeeded
        lock.unlock()
    }
}

final class EventTapResult {
    private let lock = NSLock()
    private var result: Unmanaged<CGEvent>?

    var wasSuppressed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result == nil
    }

    func set(_ result: Unmanaged<CGEvent>?) {
        lock.lock()
        self.result = result
        lock.unlock()
    }
}
