import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import XCTest

@testable import MacClippyPlatform

final class SyntheticFocusContext: MacClippySnippetFocusContextSource {
    private let lock = NSLock()
    private var identity: MacClippySnippetFocusIdentity?
    private var current: MacClippySnippetFocusIdentity?
    private var selection: MacClippySnippetTextSelection?
    private var currentSelectionValue: MacClippySnippetTextSelection?
    private var onChange: (() -> Void)?
    private var currentContextReadCountValue = 0
    private var currentContextReadHandler: ((Int, MacClippySnippetFocusContext) -> Void)?

    var cachedIdentity: MacClippySnippetFocusIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return identity
    }

    var cachedSelection: MacClippySnippetTextSelection? {
        lock.lock()
        defer { lock.unlock() }
        return selection
    }

    func currentIdentity() -> MacClippySnippetFocusIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func currentContext() -> MacClippySnippetFocusContext? {
        lock.lock()
        guard let current else {
            lock.unlock()
            return nil
        }
        currentContextReadCountValue += 1
        let readCount = currentContextReadCountValue
        let context = MacClippySnippetFocusContext(identity: current, selection: currentSelectionValue)
        let handler = currentContextReadHandler
        lock.unlock()
        handler?(readCount, context)
        return context
    }

    func onCurrentContextRead(
        _ handler: ((Int, MacClippySnippetFocusContext) -> Void)?
    ) {
        lock.lock()
        currentContextReadHandler = handler
        lock.unlock()
    }

    func noteInputEvent() {}

    func noteInputText(_ text: String) {
        lock.lock()
        guard !text.isEmpty else {
            selection = nil
            currentSelectionValue = nil
            lock.unlock()
            return
        }
        if let selection {
            self.selection = MacClippySnippetTextSelection(
                location: selection.location + text.utf16.count,
                length: 0
            )
        }
        if let currentSelectionValue {
            self.currentSelectionValue = MacClippySnippetTextSelection(
                location: currentSelectionValue.location + text.utf16.count,
                length: 0
            )
        }
        lock.unlock()
    }

    func start(onChange: @escaping () -> Void) {
        lock.lock()
        self.onChange = onChange
        lock.unlock()
    }

    func stop() {
        lock.lock()
        identity = nil
        current = nil
        selection = nil
        currentSelectionValue = nil
        onChange = nil
        lock.unlock()
    }

    func invalidateAndRefresh() {
        updateIdentity(nil)
    }

    func setIdentity(_ nextIdentity: MacClippySnippetFocusIdentity?) {
        updateIdentity(nextIdentity)
    }

    func setCurrentIdentityWithoutNotification(_ nextIdentity: MacClippySnippetFocusIdentity?) {
        lock.lock()
        current = nextIdentity
        currentSelectionValue = nextIdentity.map { _ in MacClippySnippetTextSelection(location: 0, length: 0) }
        lock.unlock()
    }

    func setCurrentSelectionWithoutNotification(location: Int, length: Int = 0) {
        lock.lock()
        currentSelectionValue = MacClippySnippetTextSelection(location: location, length: length)
        lock.unlock()
    }

    private func updateIdentity(_ nextIdentity: MacClippySnippetFocusIdentity?) {
        lock.lock()
        identity = nextIdentity
        current = nextIdentity
        let nextSelection = nextIdentity.map { _ in MacClippySnippetTextSelection(location: 0, length: 0) }
        selection = nextSelection
        currentSelectionValue = nextSelection
        let handler = onChange
        lock.unlock()
        handler?()
    }
}

final class ClipboardReadBlocker {
    private let started = DispatchSemaphore(value: 0)
    private let releaseSignal = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var didStart = false

    func read() -> String? {
        lock.lock()
        let shouldSignal = !didStart
        didStart = true
        lock.unlock()
        if shouldSignal { started.signal() }
        releaseSignal.wait()
        return ""
    }

    func waitUntilStarted() {
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
    }

    func release() {
        releaseSignal.signal()
    }
}

enum ExpansionRecordedAction: Equatable {
    case key(UInt16)
    case paste
    case input(type: UInt32, keyCode: UInt16, flags: UInt64)
}

final class ExpansionRecorder {
    private let lock = NSLock()
    private var keys: [UInt16] = []
    private var taps: [CGEventTapLocation] = []
    private var keyProcessIdentifiers: [Int32] = []
    private var processIdentifiers: [Int32] = []
    private var recordedActions: [ExpansionRecordedAction] = []
    private var pastes = 0
    private var finishes = 0
    private let finishExpectation = XCTestExpectation(description: "expansion worker finished")

    var postedKeys: [UInt16] {
        lock.lock()
        defer { lock.unlock() }
        return keys
    }

    var postedTaps: [CGEventTapLocation] {
        lock.lock()
        defer { lock.unlock() }
        return taps
    }

    var postedKeyProcessIdentifiers: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return keyProcessIdentifiers
    }

    var deleteCount: Int {
        postedKeys.filter { $0 == UInt16(kVK_Delete) }.count
    }

    var pasteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pastes
    }

    var pasteProcessIdentifiers: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return processIdentifiers
    }

    var actions: [ExpansionRecordedAction] {
        lock.lock()
        defer { lock.unlock() }
        return recordedActions
    }

    func waitUntilActionCount(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if actions.count >= count { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return actions.count >= count
    }

    func recordKey(_ keyCode: UInt16, tap: CGEventTapLocation, processIdentifier: Int32? = nil) {
        lock.lock()
        keys.append(keyCode)
        taps.append(tap)
        recordedActions.append(.key(keyCode))
        if let processIdentifier {
            keyProcessIdentifiers.append(processIdentifier)
        }
        lock.unlock()
    }

    func recordPaste(processIdentifier: Int32? = nil) {
        lock.lock()
        pastes += 1
        recordedActions.append(.paste)
        if let processIdentifier {
            processIdentifiers.append(processIdentifier)
        }
        lock.unlock()
    }

    func recordInputEvent(_ event: CGEvent, processIdentifier: Int32?) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        lock.lock()
        recordedActions.append(.input(
            type: UInt32(event.type.rawValue),
            keyCode: keyCode,
            flags: event.flags.rawValue
        ))
        keys.append(keyCode)
        taps.append(.cgAnnotatedSessionEventTap)
        if let processIdentifier {
            keyProcessIdentifiers.append(processIdentifier)
        }
        lock.unlock()
    }

    func recordFinish() {
        lock.lock()
        finishes += 1
        let didFinish = finishes == 1
        lock.unlock()
        if didFinish { finishExpectation.fulfill() }
    }

    func waitUntilFinished() {
        XCTAssertEqual(XCTWaiter.wait(for: [finishExpectation], timeout: 5), .completed)
    }
}
