import Carbon.HIToolbox
import CoreGraphics
import Foundation

private struct SnippetInputAdvance {
    let generation: UInt64
    let cancelledDelimiter: UInt16?
    let cancelledProcessIdentifier: Int32?
}

extension MacClippySnippetExpander {
    package static let eventsOfInterest: CGEventMask =
        (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

    package func processKeyForTesting(_ input: MacClippySnippetSyntheticKeyInput) -> Bool {
        processKey(input)
    }

    package func processMouseDownForTesting() {
        processMouseDown()
    }

    package func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            withLifecycleLock {
                if let eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
            }
            return nil
        }

        if Self.isKeyboardEvent(type), deferKeyboardInputIfNeeded(event) {
            if type == .keyDown {
                resetInputAfterDeferringEvent()
            }
            return nil
        }

        if Self.isMouseDown(type) {
            if deferInputEventIfReplayIsActive(event) {
                processMouseDown()
                return nil
            }
            processMouseDown()
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let input = keyInput(from: event)
        return processKey(input, originalEvent: event) ? nil : Unmanaged.passUnretained(event)
    }

    @discardableResult
    package func processKey(_ input: MacClippySnippetSyntheticKeyInput) -> Bool {
        processKey(input, originalEvent: nil)
    }

    @discardableResult
    private func processKey(
        _ input: MacClippySnippetSyntheticKeyInput,
        originalEvent: CGEvent?
    ) -> Bool {
        focusContext.noteInputEvent()
        var shouldRecordTypedText = true
        defer {
            if shouldRecordTypedText {
                focusContext.noteInputText(input.text)
            }
        }
        if let originalEvent, deferKeyboardInputIfNeeded(originalEvent) {
            shouldRecordTypedText = false
            resetInputAfterDeferringEvent()
            return true
        }
        let cachedIdentity = focusContext.cachedIdentity
        guard let advance = advanceInput(cachedIdentity: cachedIdentity) else { return false }
        if replayCancelledDelimiterIfNeeded(advance, originalEvent: originalEvent) {
            shouldRecordTypedText = false
            return true
        }
        guard let candidate = makeCandidate(
            from: input,
            cachedIdentity: cachedIdentity,
            generation: advance.generation
        ) else {
            refreshFocusIfNeeded(after: input)
            return false
        }
        guard injector.canInjectAutomatically,
              modeProvider() != .disabled,
              queue(candidate) else {
            return false
        }
        let isSuppressed = candidate.plan.suppressCurrentEvent
        if isSuppressed {
            shouldRecordTypedText = false
        } else {
            focusContext.noteInputText(input.text)
            shouldRecordTypedText = false
        }
        scheduleExpansion(candidate)
        return isSuppressed
    }

    package func processMouseDown() {
        focusContext.noteInputEvent()
        lifecycleLock.lock()
        inputGeneration &+= 1
        planner.reset()
        plannerFocusIdentity = nil
        plannerFocusSelection = nil
        pendingRequest = nil
        lifecycleLock.unlock()
        focusContext.invalidateAndRefresh()
    }

    package func focusContextDidChange() {
        lifecycleLock.lock()
        inputGeneration &+= 1
        planner.reset()
        plannerFocusIdentity = nil
        plannerFocusSelection = nil
        pendingRequest = nil
        lifecycleLock.unlock()
    }

    private func advanceInput(
        cachedIdentity: MacClippySnippetFocusIdentity?
    ) -> SnippetInputAdvance? {
        lifecycleLock.lock()
        guard installed else {
            lifecycleLock.unlock()
            return nil
        }

        inputGeneration &+= 1
        let generation = inputGeneration
        let canceledRequest = pendingRequest
        pendingRequest = nil
        let cancelledDelimiter: UInt16?
        let cancelledProcessIdentifier: Int32?
        if let canceledRequest,
           cachedIdentity == canceledRequest.focusIdentity,
           let delimiter = canceledRequest.plan.suppressedDelimiterKeyCode {
            cancelledDelimiter = delimiter
            cancelledProcessIdentifier = canceledRequest.focusIdentity.processIdentifier
        } else {
            cancelledDelimiter = nil
            cancelledProcessIdentifier = nil
        }
        lifecycleLock.unlock()
        return SnippetInputAdvance(
            generation: generation,
            cancelledDelimiter: cancelledDelimiter,
            cancelledProcessIdentifier: cancelledProcessIdentifier
        )
    }

    private func replayCancelledDelimiterIfNeeded(
        _ advance: SnippetInputAdvance,
        originalEvent: CGEvent?
    ) -> Bool {
        guard let delimiter = advance.cancelledDelimiter else { return false }
        resetInputAfterDeferringEvent()
        if let originalEvent {
            beginDeferredInputReplay(
                delimiter: delimiter,
                targetProcessIdentifier: advance.cancelledProcessIdentifier ?? 0,
                event: originalEvent
            )
            return true
        }
        if let processIdentifier = advance.cancelledProcessIdentifier {
            beginDeferredDelimiterReplay(delimiter, targetProcessIdentifier: processIdentifier)
        }
        return false
    }

    private func makeCandidate(
        from input: MacClippySnippetSyntheticKeyInput,
        cachedIdentity: MacClippySnippetFocusIdentity?,
        generation: UInt64
    ) -> ExpansionRequest? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard installed, inputGeneration == generation else { return nil }

        guard let cachedIdentity else {
            planner.reset()
            plannerFocusIdentity = nil
            plannerFocusSelection = nil
            return nil
        }
        resetPlannerIfFocusChanged(to: cachedIdentity)

        let isEditingKey = Self.isEditingKey(input.keyCode)
        guard !input.hasDisqualifyingModifiers, !input.text.isEmpty, !isEditingKey else {
            planner.reset()
            plannerFocusIdentity = nil
            plannerFocusSelection = nil
            return nil
        }

        return makeCandidateForCharacters(
            in: input,
            cachedIdentity: cachedIdentity,
            generation: generation
        )
    }

    private func makeCandidateForCharacters(
        in input: MacClippySnippetSyntheticKeyInput,
        cachedIdentity: MacClippySnippetFocusIdentity,
        generation: UInt64
    ) -> ExpansionRequest? {
        var inputUTF16Offset = 0
        for character in input.text {
            defer { inputUTF16Offset += String(character).utf16.count }
            if character == ";" {
                plannerFocusSelection = focusContext.cachedSelection.map {
                    MacClippySnippetTextSelection(
                        location: $0.location + inputUTF16Offset,
                        length: $0.length
                    )
                }
            }
            let triggerBeforeCharacter = planner.currentTrigger
            guard let plan = planner.handle(
                character,
                keyCode: input.keyCode,
                hasDisqualifyingModifiers: input.hasDisqualifyingModifiers
            ) else {
                if character.isWhitespace || character.isNewline {
                    plannerFocusSelection = nil
                }
                continue
            }
            let trigger = triggerBeforeCharacter ?? ""
            let insertedLength = trigger.utf16.count
                + (plan.charactersToDelete > trigger.count ? String(character).utf16.count : 0)
            let expectedSelection = plannerFocusSelection.map {
                MacClippySnippetTextSelection(location: $0.location + insertedLength, length: 0)
            }
            let focusIdentity = plannerFocusIdentity ?? cachedIdentity
            plannerFocusIdentity = nil
            plannerFocusSelection = nil
            nextRequestIdentifier &+= 1
            return ExpansionRequest(
                identifier: nextRequestIdentifier,
                plan: plan,
                focusIdentity: focusIdentity,
                expectedSelection: expectedSelection,
                lifecycleGeneration: lifecycleGeneration,
                inputGeneration: generation,
                gate: currentGate
            )
        }
        return nil
    }

    private func resetPlannerIfFocusChanged(to identity: MacClippySnippetFocusIdentity) {
        if let currentFocus = plannerFocusIdentity, currentFocus != identity {
            planner.reset()
            plannerFocusIdentity = nil
            plannerFocusSelection = nil
        }
        if plannerFocusIdentity == nil {
            plannerFocusIdentity = identity
        }
    }

    private func queue(_ request: ExpansionRequest) -> Bool {
        let latestCachedIdentity = focusContext.cachedIdentity
        lifecycleLock.lock()
        let canQueue = installed
            && lifecycleGeneration == request.lifecycleGeneration
            && inputGeneration == request.inputGeneration
            && latestCachedIdentity == request.focusIdentity
        if canQueue {
            pendingRequest = request
        }
        lifecycleLock.unlock()
        return canQueue
    }

    private func refreshFocusIfNeeded(after input: MacClippySnippetSyntheticKeyInput) {
        guard Self.mayChangeFocus(input.keyCode) else { return }
        focusContext.invalidateAndRefresh()
    }

    private static func isMouseDown(_ type: CGEventType) -> Bool {
        type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }

    private static func isKeyboardEvent(_ type: CGEventType) -> Bool {
        type == .keyDown || type == .keyUp || type == .flagsChanged
    }

    private static func isEditingKey(_ keyCode: UInt16) -> Bool {
        keyCode == UInt16(kVK_Escape)
            || keyCode == UInt16(kVK_Delete)
            || keyCode == UInt16(kVK_ForwardDelete)
            || keyCode == UInt16(kVK_LeftArrow)
            || keyCode == UInt16(kVK_RightArrow)
            || keyCode == UInt16(kVK_UpArrow)
            || keyCode == UInt16(kVK_DownArrow)
    }

    private static func mayChangeFocus(_ keyCode: UInt16) -> Bool {
        isEditingKey(keyCode)
            || keyCode == UInt16(kVK_Tab)
            || keyCode == UInt16(kVK_Return)
    }

    private func keyInput(from event: CGEvent) -> MacClippySnippetSyntheticKeyInput {
        var actualLength = 0
        var characters = [UniChar](repeating: 0, count: 64)
        event.keyboardGetUnicodeString(
            maxStringLength: characters.count,
            actualStringLength: &actualLength,
            unicodeString: &characters
        )
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let rawString = Self.string(fromUTF16: characters.prefix(actualLength))
        let typedString = rawString.isEmpty && keyCode == UInt16(kVK_Tab) ? "\t" : rawString
        let flags = event.flags
        return MacClippySnippetSyntheticKeyInput(
            text: typedString,
            keyCode: keyCode,
            hasDisqualifyingModifiers: flags.contains(.maskCommand)
                || flags.contains(.maskControl)
                || flags.contains(.maskAlternate)
        )
    }

    private static func string(fromUTF16 units: ArraySlice<UniChar>) -> String {
        var scalars = String.UnicodeScalarView()
        var index = units.startIndex
        while index < units.endIndex {
            let first = units[index]
            if (0xD800...0xDBFF).contains(first) {
                let nextIndex = units.index(after: index)
                if nextIndex < units.endIndex, (0xDC00...0xDFFF).contains(units[nextIndex]) {
                    let high = UInt32(first) - 0xD800
                    let low = UInt32(units[nextIndex]) - 0xDC00
                    if let scalar = Unicode.Scalar(0x1_0000 + (high << 10) + low) {
                        scalars.append(scalar)
                    }
                    index = units.index(after: nextIndex)
                } else {
                    // Keep malformed UTF-16 handling compatible with the old
                    // decoder: ignore unpaired surrogates, without inserting
                    // a replacement character into the trigger buffer.
                    index = nextIndex
                }
                continue
            }
            if (0xDC00...0xDFFF).contains(first) {
                index = units.index(after: index)
                continue
            }
            if let scalar = Unicode.Scalar(first) {
                scalars.append(scalar)
            }
            index = units.index(after: index)
        }
        return String(scalars)
    }
}
