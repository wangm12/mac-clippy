import CoreGraphics
import Foundation

package enum MacClippySnippetDeferredInputItem {
    case keyCode(UInt16, targetProcessIdentifier: Int32?)
    case event(CGEvent, targetProcessIdentifier: Int32?)
}

extension MacClippySnippetExpander {
    /// Adds keyboard input to the serial replay queue while a commit or
    /// previously suppressed Tab is being completed. Returning true means the
    /// event tap must suppress the original event.
    package func deferKeyboardInputIfNeeded(_ event: CGEvent) -> Bool {
        lifecycleLock.lock()
        guard committingRequestIdentifier != nil || deferredInputReplayActive else {
            lifecycleLock.unlock()
            return false
        }
        let processIdentifier = eventTargetProcessIdentifier(in: event)
            ?? committingProcessIdentifier
        deferredInputReplayItems.append(.event(
            event.copy() ?? event,
            targetProcessIdentifier: processIdentifier
        ))
        let shouldStartDraining = committingRequestIdentifier == nil
            && !deferredInputReplayScheduled
        if shouldStartDraining {
            deferredInputReplayActive = true
            deferredInputReplayScheduled = true
        }
        lifecycleLock.unlock()

        if shouldStartDraining {
            deferredInputReplayQueue.async {
                self.drainDeferredInputReplay()
            }
        }
        return true
    }

    /// Adds a mouse event only while a prior canceled Tab replay is active.
    /// Mouse events during a committed Delete+Paste pair remain live so AX can
    /// observe focus changes; keyboard events are held until the pair finishes.
    package func deferInputEventIfReplayIsActive(_ event: CGEvent) -> Bool {
        lifecycleLock.lock()
        guard deferredInputReplayActive, committingRequestIdentifier == nil else {
            lifecycleLock.unlock()
            return false
        }
        deferredInputReplayItems.append(.event(
            event.copy() ?? event,
            targetProcessIdentifier: eventTargetProcessIdentifier(in: event)
        ))
        lifecycleLock.unlock()
        return true
    }

    package func beginDeferredInputReplay(
        delimiter: UInt16,
        targetProcessIdentifier: Int32?,
        event: CGEvent
    ) {
        enqueueDeferredInputReplay([
            .keyCode(delimiter, targetProcessIdentifier: targetProcessIdentifier),
            .event(
                event.copy() ?? event,
                targetProcessIdentifier: eventTargetProcessIdentifier(in: event)
            )
        ])
    }

    package func beginDeferredDelimiterReplay(_ delimiter: UInt16, targetProcessIdentifier: Int32?) {
        enqueueDeferredInputReplay([
            .keyCode(delimiter, targetProcessIdentifier: targetProcessIdentifier)
        ])
    }

    package func resetInputAfterDeferringEvent() {
        lifecycleLock.lock()
        inputGeneration &+= 1
        planner.reset()
        plannerFocusIdentity = nil
        plannerFocusSelection = nil
        pendingRequest = nil
        lifecycleLock.unlock()
    }

    private func enqueueDeferredInputReplay(_ items: [MacClippySnippetDeferredInputItem]) {
        lifecycleLock.lock()
        deferredInputReplayItems.append(contentsOf: items)
        let shouldStartDraining = !deferredInputReplayScheduled
        deferredInputReplayActive = true
        if shouldStartDraining, committingRequestIdentifier == nil {
            deferredInputReplayScheduled = true
        }
        let shouldQueueDrain = shouldStartDraining && committingRequestIdentifier == nil
        lifecycleLock.unlock()

        guard shouldQueueDrain else { return }
        deferredInputReplayQueue.async {
            self.drainDeferredInputReplay()
        }
    }

    package func drainDeferredInputReplay() {
        while true {
            lifecycleLock.lock()
            guard committingRequestIdentifier == nil else {
                deferredInputReplayScheduled = false
                lifecycleLock.unlock()
                return
            }
            guard !deferredInputReplayItems.isEmpty else {
                deferredInputReplayActive = false
                deferredInputReplayScheduled = false
                let shouldFinishStop = stopCleanupPending
                lifecycleLock.unlock()
                if shouldFinishStop {
                    finishDeferredStopIfNeeded()
                }
                return
            }
            let item = deferredInputReplayItems.removeFirst()
            lifecycleLock.unlock()

            switch item {
            case let .keyCode(keyCode, processIdentifier):
                _ = keyPoster.post(keyCode: keyCode, targetProcessIdentifier: processIdentifier)
            case let .event(event, processIdentifier):
                keyPoster.post(event: event, targetProcessIdentifier: processIdentifier)
            }
        }
    }

    private func eventTargetProcessIdentifier(in event: CGEvent) -> Int32? {
        let processIdentifier = event.getIntegerValueField(.eventTargetUnixProcessID)
        guard processIdentifier > 0, processIdentifier <= Int64(Int32.max) else { return nil }
        return Int32(processIdentifier)
    }
}
