import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private struct PasteInjectionPlan {
    let original: MacClippyPasteInjector.PasteboardSnapshot
    let prepared: MacClippyPasteInjector.PasteboardSnapshot
    let events: MacClippyPasteInjector.PasteEvents?
    let isTrusted: Bool
    var ownedChangeCount: Int?
}

private enum PasteInjectionPlanResult {
    case ready(PasteInjectionPlan)
    case finished(MacClippyPasteInjectionResult)
}

private enum PasteInjectionWriteResult {
    case ready(PasteInjectionPlan)
    case finished(MacClippyPasteInjectionResult)
}

extension MacClippyPasteInjector {
    func injectLocked(
        content: MacClippyPasteboardContent,
        request: InjectionRequest
    ) -> MacClippyPasteInjectionResult {
        switch makeInjectionPlan(content: content, request: request) {
        case let .finished(result):
            return result
        case let .ready(plan):
            switch writeInjectionPlan(plan, request: request) {
            case let .finished(result):
                return result
            case let .ready(writtenPlan):
                return commitInjectionPlan(writtenPlan, request: request)
            }
        }
    }

    func performGated<T>(
        _ gate: MacClippyPasteInjectionGate?,
        _ operation: () -> T
    ) -> T? {
        guard let gate else { return operation() }
        return gate.withCommitGate(operation)
    }
}

private extension MacClippyPasteInjector {
    func makeInjectionPlan(
        content: MacClippyPasteboardContent,
        request: InjectionRequest
    ) -> PasteInjectionPlanResult {
        guard request.gate?.isOpen != false else { return .finished(.cancelled) }
        let original = snapshotPasteboard(pasteboard)
        guard original.isComplete else { return .finished(.failed(.incompleteClipboard)) }
        guard let prepared = preparedSnapshot(for: content) else {
            return .finished(.failed(.preparationFailed))
        }
        guard request.gate?.isOpen != false else { return .finished(.cancelled) }
        guard (try? MacClippyNativePasteboard.changeCount(of: pasteboard)) == original.changeCount else {
            return .finished(.failed(.clipboardChanged))
        }
        guard validate(request.validateBeforePaste) else { return .finished(.cancelled) }
        guard request.gate?.isOpen != false else { return .finished(.cancelled) }

        let trusted = isProcessTrusted()
        guard trusted || request.manualFallback == .prepareClipboard else {
            return .finished(.failed(.accessibilityUnavailable))
        }
        let events = trusted ? pasteEvents() : nil
        guard events != nil || request.manualFallback == .prepareClipboard else {
            return .finished(.failed(.eventCreationFailed))
        }
        return .ready(PasteInjectionPlan(
            original: original,
            prepared: prepared,
            events: events,
            isTrusted: trusted,
            ownedChangeCount: nil
        ))
    }

    func writeInjectionPlan(
        _ plan: PasteInjectionPlan,
        request: InjectionRequest
    ) -> PasteInjectionWriteResult {
        let result = writeSnapshot(
            plan.prepared,
            to: pasteboard,
            sentinel: writeSentinel,
            expectedChangeCount: plan.original.changeCount,
            gate: request.gate
        )
        switch result {
        case let .written(changeCount):
            guard request.gate?.isOpen != false else {
                return finishFailedWrite(plan, .cancelled, expectedCount: changeCount)
            }
            var writtenPlan = plan
            writtenPlan.ownedChangeCount = changeCount
            return .ready(writtenPlan)
        case let .failed(expectedCount):
            return finishFailedWrite(plan, .failed(.pasteboardWriteFailed), expectedCount: expectedCount)
        case let .cancelled(expectedCount):
            return finishFailedWrite(plan, .cancelled, expectedCount: expectedCount)
        case .clipboardChanged:
            return .finished(.failed(.clipboardChanged))
        case .restoreFailed:
            return .finished(.failed(.clipboardRestoreFailed))
        }
    }

    func finishFailedWrite(
        _ plan: PasteInjectionPlan,
        _ result: MacClippyPasteInjectionResult,
        expectedCount: Int?
    ) -> PasteInjectionWriteResult {
        guard let ownedChangeCount = expectedCount else {
            return .finished(result)
        }
        guard pasteboardAccessCoordinator.withAccess({
            (try? MacClippyNativePasteboard.changeCount(of: pasteboard)) == ownedChangeCount
        }) else {
            return .finished(.failed(.clipboardChanged))
        }
        switch restore(plan.original, onlyIfChangeCountIs: ownedChangeCount) {
        case .restored:
            return .finished(result)
        case .ownershipLost:
            return .finished(.failed(.clipboardChanged))
        case .writeFailed:
            return .finished(.failed(.clipboardRestoreFailed))
        case .ambiguousFailure:
            return .finished(.failed(.clipboardRestoreFailed))
        }
    }

    func commitInjectionPlan(
        _ plan: PasteInjectionPlan,
        request: InjectionRequest
    ) -> MacClippyPasteInjectionResult {
        guard let ownedChangeCount = plan.ownedChangeCount else {
            return .failed(.clipboardChanged)
        }
        if let failure = commitPreflightFailure(plan, request: request, ownedChangeCount: ownedChangeCount) {
            return failure
        }
        guard let events = plan.events else { return .failed(.eventCreationFailed) }

        if let beforePaste = request.beforePaste {
            return commitAfterBeforePaste(
                beforePaste,
                events: events,
                plan: plan,
                request: request,
                ownedChangeCount: ownedChangeCount
            )
        }
        preEventAdmissionHookForTesting?()
        let result = postPasteEvents(
            events,
            gate: request.gate,
            targetProcessIdentifier: request.targetProcessIdentifier,
            expectedPasteboardChangeCount: ownedChangeCount,
            afterPasteEvents: request.afterPasteEvents
        )
        guard result == .cancelled else { return result }
        return restoreAndReturn(plan, result: .cancelled)
    }

    func commitPreflightFailure(
        _ plan: PasteInjectionPlan,
        request: InjectionRequest,
        ownedChangeCount: Int
    ) -> MacClippyPasteInjectionResult? {
        guard pasteboardAccessCoordinator.withAccess({
            (try? MacClippyNativePasteboard.changeCount(of: pasteboard)) == ownedChangeCount
        }) else {
            return .failed(.clipboardChanged)
        }
        guard plan.isTrusted, plan.events != nil, isProcessTrusted() else {
            return finishManualFallback(plan, request: request)
        }
        guard request.gate?.isOpen != false,
              validate(request.validateCommitContext),
              request.gate?.isOpen != false else {
            return restoreAndReturn(plan, result: .cancelled)
        }
        return nil
    }

    func commitAfterBeforePaste(
        _ beforePaste: () -> Bool,
        events: PasteEvents,
        plan: PasteInjectionPlan,
        request: InjectionRequest,
        ownedChangeCount: Int
    ) -> MacClippyPasteInjectionResult {
        guard let committed = performGated(request.gate, {
            guard (try? MacClippyNativePasteboard.changeCount(of: pasteboard)) == ownedChangeCount else {
                return PasteInjectionCommitResult.clipboardChanged
            }
            guard beforePaste() else { return PasteInjectionCommitResult.cancelled }
            postCommittedPasteEvents(
                events,
                gate: request.gate,
                targetProcessIdentifier: request.targetProcessIdentifier,
                afterPasteEvents: request.afterPasteEvents
            )
            return PasteInjectionCommitResult.injected
        }) else {
            return restoreAndReturn(plan, result: .cancelled)
        }
        switch committed {
        case .injected:
            return .injected
        case .cancelled:
            return restoreAndReturn(plan, result: .cancelled)
        case .clipboardChanged:
            return .failed(.clipboardChanged)
        }
    }

    func finishManualFallback(
        _ plan: PasteInjectionPlan,
        request: InjectionRequest
    ) -> MacClippyPasteInjectionResult {
        guard let ownedChangeCount = plan.ownedChangeCount,
              pasteboardAccessCoordinator.withAccess({
                  (try? MacClippyNativePasteboard.changeCount(of: pasteboard)) == ownedChangeCount
              }) else {
            return .failed(.clipboardChanged)
        }
        guard request.manualFallback == .prepareClipboard else {
            return restoreAndReturn(plan, result: .failed(.accessibilityUnavailable))
        }
        return request.gate?.isOpen == false
            ? restoreAndReturn(plan, result: .cancelled)
            : .preparedForManualPaste
    }

    func restoreAndReturn(
        _ plan: PasteInjectionPlan,
        result: MacClippyPasteInjectionResult
    ) -> MacClippyPasteInjectionResult {
        guard let ownedChangeCount = plan.ownedChangeCount,
              pasteboardAccessCoordinator.withAccess({
                  (try? MacClippyNativePasteboard.changeCount(of: pasteboard)) == ownedChangeCount
              }) else {
            return .failed(.clipboardChanged)
        }
        switch restore(plan.original, onlyIfChangeCountIs: ownedChangeCount) {
        case .restored:
            return result
        case .ownershipLost:
            return .failed(.clipboardChanged)
        case .writeFailed:
            return .failed(.clipboardRestoreFailed)
        case .ambiguousFailure:
            return .failed(.clipboardRestoreFailed)
        }
    }

    func postPasteEvents(
        _ events: PasteEvents,
        gate: MacClippyPasteInjectionGate?,
        targetProcessIdentifier: Int32? = nil,
        expectedPasteboardChangeCount: Int,
        afterPasteEvents: (() -> Void)? = nil
    ) -> MacClippyPasteInjectionResult {
        guard gate?.isOpen != false else { return .cancelled }
        let posted: PasteInjectionCommitResult? = performGated(gate) {
            guard pasteboardAccessCoordinator.withAccess({
                (try? MacClippyNativePasteboard.changeCount(of: pasteboard)) == expectedPasteboardChangeCount
            }) else { return .clipboardChanged }
            postPasteKeystrokeNotification(.macClippyWillInjectPasteKeystroke)
            postEvents(events, to: targetProcessIdentifier)
            completePasteEvents(gate: gate, afterPasteEvents: afterPasteEvents)
            return .injected
        }
        switch posted {
        case .injected:
            return .injected
        case .cancelled, nil:
            return .cancelled
        case .clipboardChanged:
            return .failed(.clipboardChanged)
        }
    }

    func postCommittedPasteEvents(
        _ events: PasteEvents,
        gate: MacClippyPasteInjectionGate?,
        targetProcessIdentifier: Int32? = nil,
        afterPasteEvents: (() -> Void)? = nil
    ) {
        postPasteKeystrokeNotification(.macClippyWillInjectPasteKeystroke)
        postEvents(events, to: targetProcessIdentifier)
        completePasteEvents(gate: gate, afterPasteEvents: afterPasteEvents)
    }

    private func completePasteEvents(
        gate: MacClippyPasteInjectionGate?,
        afterPasteEvents: (() -> Void)?
    ) {
        if gate?.isOpen != false {
            postPasteKeystrokeNotification(.macClippyDidInjectPasteKeystroke)
        }
        afterPasteEvents?()
    }

    private func postEvents(_ events: PasteEvents, to processIdentifier: Int32?) {
        guard let processIdentifier else {
            postEvents(events.keyDown, events.keyUp)
            return
        }
        if let postEventsToProcess {
            postEventsToProcess(events.keyDown, events.keyUp, processIdentifier)
        } else {
            events.keyDown.postToPid(pid_t(processIdentifier))
            events.keyUp.postToPid(pid_t(processIdentifier))
        }
    }

    func validate(_ validation: (() -> Bool)?) -> Bool {
        validation?() ?? true
    }

    func pasteEvents() -> PasteEvents? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return nil
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        return PasteEvents(keyDown: keyDown, keyUp: keyUp)
    }

    func postPasteKeystrokeNotification(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: self)
    }
}

private enum PasteInjectionCommitResult {
    case injected
    case cancelled
    case clipboardChanged
}
