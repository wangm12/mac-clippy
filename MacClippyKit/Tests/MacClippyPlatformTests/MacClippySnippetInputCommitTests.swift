import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class MacClippySnippetInputCommitTests: XCTestCase {
    func testCancelledTabReplayDoesNotBlockInputTapAndPreservesEventOrder() {
        let blocker = ClipboardReadBlocker()
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let tabPostStarted = DispatchSemaphore(value: 0)
        let releaseTabPost = DispatchSemaphore(value: 0)
        let expander = makeExpander(
            focus: focus,
            recorder: recorder,
            mode: .confirmWithTab,
            clipboardTextProvider: blocker.read,
            postKeyEvents: { keyDown, _, tap in
                let keyCode = UInt16(keyDown.getIntegerValueField(.keyboardEventKeycode))
                recorder.recordKey(keyCode, tap: tap)
                if keyCode == UInt16(kVK_Tab) {
                    tabPostStarted.signal()
                    _ = releaseTabPost.wait(timeout: .now() + 5)
                }
            }
        )
        expander.startForTesting()
        defer {
            releaseTabPost.signal()
            blocker.release()
            expander.stop()
        }

        typeCharacters(";email", on: expander)
        XCTAssertTrue(expander.processKeyForTesting(.init(text: "\t", keyCode: UInt16(kVK_Tab))))
        blocker.waitUntilStarted()
        XCTAssertTrue(handleInputAsynchronously(targetedKeyEvent(UInt16(kVK_Escape)), on: expander))
        XCTAssertEqual(tabPostStarted.wait(timeout: .now() + 2), .success)

        XCTAssertTrue(handleInputAsynchronously(targetedKeyEvent(7), on: expander))

        releaseTabPost.signal()
        blocker.release()
        recorder.waitUntilFinished()
        XCTAssertTrue(recorder.waitUntilActionCount(3))
        XCTAssertEqual(
            recorder.postedKeys.filter { $0 != UInt16(kVK_Delete) },
            [UInt16(kVK_Tab), UInt16(kVK_Escape), 7]
        )
    }

    private func handleInputAsynchronously(_ event: CGEvent, on expander: MacClippySnippetExpander) -> Bool {
        let result = EventTapResult()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            result.set(expander.handle(type: .keyDown, event: event))
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        return result.wasSuppressed
    }

    func testInputDuringDeletePasteCommitReplaysInOrderAndStopDoesNotWait() {
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let deleteStarted = DispatchSemaphore(value: 0)
        let releaseDelete = DispatchSemaphore(value: 0)
        let expander = makeExpander(
            focus: focus,
            recorder: recorder,
            onDelete: firstDeleteBlocker(started: deleteStarted, release: releaseDelete)
        )
        expander.startForTesting()
        defer {
            releaseDelete.signal()
            expander.stop()
        }

        typeTriggerAndDelimiter(on: expander)
        XCTAssertEqual(deleteStarted.wait(timeout: .now() + 3), .success)
        XCTAssertNil(expander.handle(type: .keyDown, event: keyEvent(UInt16(kVK_Escape))))
        XCTAssertNil(expander.handle(type: .keyUp, event: keyEvent(UInt16(kVK_Escape), down: false)))

        let stopStart = Date()
        expander.stop()
        XCTAssertLessThan(Date().timeIntervalSince(stopStart), 1)

        assertDeferredModifierAndTextEvents(on: expander)
        releaseDelete.signal()
        recorder.waitUntilFinished()
        XCTAssertTrue(recorder.waitUntilActionCount(14))
        assertCommitThenInputWasRecorded(recorder)
    }

    private func firstDeleteBlocker(
        started: DispatchSemaphore,
        release: DispatchSemaphore
    ) -> () -> Void {
        let lock = NSLock()
        var hasBlocked = false
        return {
            lock.lock()
            let shouldBlock = !hasBlocked
            hasBlocked = true
            lock.unlock()
            guard shouldBlock else { return }
            started.signal()
            _ = release.wait(timeout: .now() + 5)
        }
    }

    private func assertDeferredModifierAndTextEvents(on expander: MacClippySnippetExpander) {
        let events: [(CGEventType, CGEvent)] = [
            (.flagsChanged, flagsChangedEvent(UInt16(kVK_Shift), flags: .maskShift)),
            (.keyDown, keyEvent(7, flags: .maskShift)),
            (.keyUp, keyEvent(7, down: false, flags: .maskShift)),
            (.flagsChanged, flagsChangedEvent(UInt16(kVK_Shift), flags: []))
        ]
        for (type, event) in events {
            XCTAssertNil(expander.handle(type: type, event: event))
        }
    }

    private func assertCommitThenInputWasRecorded(_ recorder: ExpansionRecorder) {
        let expectedInput: [ExpansionRecordedAction] = [
            .input(type: UInt32(CGEventType.keyDown.rawValue), keyCode: UInt16(kVK_Escape), flags: 0),
            .input(type: UInt32(CGEventType.keyUp.rawValue), keyCode: UInt16(kVK_Escape), flags: 0),
            .input(
                type: UInt32(CGEventType.flagsChanged.rawValue),
                keyCode: UInt16(kVK_Shift),
                flags: CGEventFlags.maskShift.rawValue
            ),
            .input(type: UInt32(CGEventType.keyDown.rawValue), keyCode: 7, flags: CGEventFlags.maskShift.rawValue),
            .input(type: UInt32(CGEventType.keyUp.rawValue), keyCode: 7, flags: CGEventFlags.maskShift.rawValue),
            .input(
                type: UInt32(CGEventType.flagsChanged.rawValue),
                keyCode: UInt16(kVK_Shift),
                flags: 0
            )
        ]
        let expectedActions = Array(repeating: .key(UInt16(kVK_Delete)), count: 7) + [.paste] + expectedInput
        XCTAssertEqual(recorder.actions, expectedActions)
        XCTAssertEqual(
            Array(recorder.postedKeyProcessIdentifiers.suffix(expectedInput.count)),
            Array(repeating: 101, count: expectedInput.count)
        )
    }

    private func makeExpander(
        focus: SyntheticFocusContext,
        recorder: ExpansionRecorder,
        mode: MacClippySnippetExpansionMode = .autoExpand,
        clipboardTextProvider: @escaping () -> String? = { nil },
        onDelete: @escaping () -> Void = {},
        postKeyEvents: MacClippySnippetKeyPoster.Post? = nil
    ) -> MacClippySnippetExpander {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippySnippetInputCommit-\(UUID().uuidString)"))
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in recorder.recordPaste() },
            postEventsToProcess: { _, _, processIdentifier in
                recorder.recordPaste(processIdentifier: processIdentifier)
            }
        )
        let keyPoster = MacClippySnippetKeyPoster(
            postEvents: { keyDown, keyUp, tap in
                let keyCode = UInt16(keyDown.getIntegerValueField(.keyboardEventKeycode))
                if let postKeyEvents {
                    postKeyEvents(keyDown, keyUp, tap)
                } else {
                    recorder.recordKey(keyCode, tap: tap)
                }
                if keyCode == UInt16(kVK_Delete) { onDelete() }
            },
            postEvent: { _, _ in XCTFail("Synthetic input must not reach the global event poster") },
            postEventsToProcess: { keyDown, keyUp, processIdentifier in
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
                if keyCode == UInt16(kVK_Delete) { onDelete() }
            },
            postEventToProcess: { event, processIdentifier in
                recorder.recordInputEvent(event, processIdentifier: processIdentifier)
            }
        )
        return MacClippySnippetExpander(
            modeProvider: { mode },
            lookup: { $0 == ";email" ? "expanded@example.test" : nil },
            injector: injector,
            keyPoster: keyPoster,
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

    private func keyEvent(
        _ keyCode: UInt16,
        down: Bool = true,
        flags: CGEventFlags = []
    ) -> CGEvent {
        let source = CGEventSource(stateID: .combinedSessionState)!
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: down)!
        event.flags = flags
        return event
    }

    private func targetedKeyEvent(_ keyCode: UInt16) -> CGEvent {
        let event = keyEvent(keyCode)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 101)
        return event
    }

    private func flagsChangedEvent(_ keyCode: UInt16, flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(source: CGEventSource(stateID: .combinedSessionState))!
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        event.flags = flags
        return event
    }

    private func identity(pid: Int32, element: UInt64) -> MacClippySnippetFocusIdentity {
        MacClippySnippetFocusIdentity(processIdentifier: pid, elementIdentity: element)
    }
}
