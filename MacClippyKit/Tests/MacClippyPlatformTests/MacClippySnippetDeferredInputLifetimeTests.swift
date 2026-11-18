import AppKit
import Carbon.HIToolbox
import CoreGraphics
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class SnippetDeferredLifetimeTests: XCTestCase {
    func testQueuedReplayRetainsOwnerUntilInputAndTapCleanupComplete() {
        let focus = SyntheticFocusContext()
        focus.setIdentity(identity(pid: 101, element: 1))
        let recorder = ExpansionRecorder()
        let deleteStarted = DispatchSemaphore(value: 0)
        let releaseDelete = DispatchSemaphore(value: 0)
        let replayStarted = DispatchSemaphore(value: 0)
        let releaseReplay = DispatchSemaphore(value: 0)
        let expansionQueueStarted = DispatchSemaphore(value: 0)
        let releaseExpansionQueue = DispatchSemaphore(value: 0)
        let expansionFinished = DispatchSemaphore(value: 0)
        let fakeResources = makeRunLoopResources()
        var expander: MacClippySnippetExpander? = makeExpander(
            focus: focus,
            recorder: recorder,
            deleteStarted: deleteStarted,
            releaseDelete: releaseDelete,
            expansionFinished: expansionFinished
        )
        installSyntheticTap(on: expander!, resources: fakeResources)

        blockExpansionQueue(
            of: expander!,
            started: expansionQueueStarted,
            release: releaseExpansionQueue
        )
        blockReplayQueue(of: expander!, started: replayStarted, release: releaseReplay)
        typeTriggerAndDelimiter(on: expander!)
        releaseExpansionQueue.signal()
        XCTAssertEqual(deleteStarted.wait(timeout: .now() + 3), .success)
        XCTAssertNil(expander?.handle(type: .keyDown, event: keyEvent(UInt16(kVK_Escape))))
        let bufferedInputCount = expander!.withLifecycleLock { expander!.deferredInputReplayItems.count }
        XCTAssertEqual(bufferedInputCount, 1)
        releaseDelete.signal()
        XCTAssertEqual(expansionFinished.wait(timeout: .now() + 3), .success)
        let hasScheduledReplay = expander!.withLifecycleLock { expander!.deferredInputReplayScheduled }
        XCTAssertTrue(hasScheduledReplay)

        let weakExpander = WeakSnippetExpander(expander)
        let stopStartedAt = Date()
        expander?.stop()
        XCTAssertLessThan(Date().timeIntervalSince(stopStartedAt), 1)
        XCTAssertTrue(CFMachPortIsValid(fakeResources.port))
        XCTAssertTrue(CFRunLoopContainsSource(CFRunLoopGetMain(), fakeResources.source, .commonModes))
        expander = nil
        assertOwnerRemainsAliveForQueuedReplay(weakExpander)

        releaseReplay.signal()
        assertDeferredReplayDelivered(
            recorder: recorder,
            resources: fakeResources,
            weakExpander: weakExpander
        )
    }

    private func assertDeferredReplayDelivered(
        recorder: ExpansionRecorder,
        resources: (port: CFMachPort, source: CFRunLoopSource),
        weakExpander: WeakSnippetExpander
    ) {
        XCTAssertTrue(waitUntilResourcesAreRetired(resources, weakExpander: weakExpander))
        XCTAssertTrue(recorder.actions.contains(where: {
            if case let .input(type, keyCode, _) = $0 {
                return type == UInt32(CGEventType.keyDown.rawValue) && keyCode == UInt16(kVK_Escape)
            }
            return false
        }), "deferred Escape event was not replayed: \(recorder.actions)")
        XCTAssertFalse(CFMachPortIsValid(resources.port))
        XCTAssertFalse(CFRunLoopContainsSource(CFRunLoopGetMain(), resources.source, .commonModes))
    }

    private func assertOwnerRemainsAliveForQueuedReplay(_ weakExpander: WeakSnippetExpander) {
        XCTAssertNotNil(weakExpander.value, "queued replay must keep the event-tap owner alive")
    }

    private func installSyntheticTap(
        on expander: MacClippySnippetExpander,
        resources: (port: CFMachPort, source: CFRunLoopSource)
    ) {
        expander.startForTesting()
        expander.eventTap = resources.port
        expander.runLoopSource = resources.source
    }

    private func makeExpander(
        focus: SyntheticFocusContext,
        recorder: ExpansionRecorder,
        deleteStarted: DispatchSemaphore,
        releaseDelete: DispatchSemaphore,
        expansionFinished: DispatchSemaphore
    ) -> MacClippySnippetExpander {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SnippetLifetime-\(UUID().uuidString)"))
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in XCTFail("lifetime test must not use the global paste poster") },
            postEventsToProcess: { _, _, pid in recorder.recordPaste(processIdentifier: pid) }
        )
        let deleteLock = NSLock()
        var blockedDelete = false
        let keyPoster = MacClippySnippetKeyPoster(
            postEvents: { _, _, _ in XCTFail("lifetime test must not use the global key poster") },
            postEvent: { _, _ in XCTFail("lifetime test must not use the global event poster") },
            postEventsToProcess: { keyDown, _, pid in
                let keyCode = UInt16(keyDown.getIntegerValueField(.keyboardEventKeycode))
                recorder.recordKey(keyCode, tap: .cgAnnotatedSessionEventTap, processIdentifier: pid)
                deleteLock.lock()
                let shouldBlock = keyCode == UInt16(kVK_Delete) && !blockedDelete
                if shouldBlock { blockedDelete = true }
                deleteLock.unlock()
                if shouldBlock {
                    deleteStarted.signal()
                    _ = releaseDelete.wait(timeout: .now() + 5)
                }
            },
            postEventToProcess: { event, pid in recorder.recordInputEvent(event, processIdentifier: pid) }
        )
        return MacClippySnippetExpander(
            modeProvider: { .autoExpand },
            lookup: { $0 == ";email" ? "expanded@example.test" : nil },
            injector: injector,
            keyPoster: keyPoster,
            focusContext: focus,
            clipboardTextProvider: { nil },
            expansionDidFinish: { expansionFinished.signal() }
        )
    }

    private func blockExpansionQueue(
        of expander: MacClippySnippetExpander,
        started: DispatchSemaphore,
        release: DispatchSemaphore
    ) {
        expander.expansionQueue.async {
            started.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
    }

    private func blockReplayQueue(
        of expander: MacClippySnippetExpander,
        started: DispatchSemaphore,
        release: DispatchSemaphore
    ) {
        expander.deferredInputReplayQueue.async {
            started.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
    }

    private func typeTriggerAndDelimiter(on expander: MacClippySnippetExpander) {
        for character in ";email" {
            XCTAssertFalse(expander.processKeyForTesting(.init(text: String(character))))
        }
        XCTAssertFalse(expander.processKeyForTesting(.init(text: " ", keyCode: UInt16(kVK_Space))))
    }

    private func keyEvent(_ keyCode: UInt16) -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: CGEventSource(stateID: .combinedSessionState),
            virtualKey: CGKeyCode(keyCode),
            keyDown: true
        )!
        event.setIntegerValueField(.eventTargetUnixProcessID, value: 101)
        return event
    }

    private func makeRunLoopResources() -> (port: CFMachPort, source: CFRunLoopSource) {
        let callback: CFMachPortCallBack = { _, _, _, _ in }
        var context = CFMachPortContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        var shouldFreeInfo = DarwinBoolean(false)
        let port = CFMachPortCreate(kCFAllocatorDefault, callback, &context, &shouldFreeInfo)!
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return (port, source)
    }

    private func waitUntilResourcesAreRetired(
        _ resources: (port: CFMachPort, source: CFRunLoopSource),
        weakExpander: WeakSnippetExpander
    ) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if weakExpander.value == nil,
               !CFMachPortIsValid(resources.port),
               !CFRunLoopContainsSource(CFRunLoopGetMain(), resources.source, .commonModes) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return false
    }

    private func identity(pid: Int32, element: UInt64) -> MacClippySnippetFocusIdentity {
        MacClippySnippetFocusIdentity(processIdentifier: pid, elementIdentity: element)
    }
}

private final class WeakSnippetExpander {
    weak var value: MacClippySnippetExpander?

    init(_ value: MacClippySnippetExpander?) {
        self.value = value
    }
}
