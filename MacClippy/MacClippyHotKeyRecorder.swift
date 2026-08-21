import AppKit
import Carbon.HIToolbox
import CoreGraphics
import MacClippyPlatform
import SwiftUI

struct MacClippyHotKeyRecorder: View {
    @Binding var descriptor: MacClippyGlobalHotKeyDescriptor
    var onChange: (MacClippyGlobalHotKeyDescriptor) -> Void

    @State private var isRecording = false
    @State private var keyMonitor: Any?
    @State private var eventTap: MacClippyHotKeyEventTap?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(isRecording ? "Type shortcut…" : descriptor.symbolicDisplay)
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Clipboard shortcut")
            .accessibilityValue(isRecording ? "Recording" : descriptor.symbolicDisplay)
            .accessibilityHint(isRecording ? "Type a new shortcut" : "Click to record a new shortcut")

            Button {
                stopRecording()
                let defaultDescriptor = MacClippyGlobalHotKeyDescriptor.defaultClipboard
                MacClippyGlobalHotKeyDescriptor.save(defaultDescriptor)
                descriptor = defaultDescriptor
                onChange(defaultDescriptor)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .controlSize(.small)
            .accessibilityLabel("Reset shortcut")
            .help("Reset shortcut")
        }
        .onDisappear {
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .macClippyHotKeyRecordingEvent)) { notification in
            handleCapturedEvent(notification)
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        NotificationCenter.default.post(
            name: .macClippyHotKeyRecordingChanged,
            object: nil,
            userInfo: [MacClippyHotKeyNotificationUserInfo.isActive: true]
        )
        let eventTap = MacClippyHotKeyEventTap()
        if eventTap.start() {
            self.eventTap = eventTap
        } else {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                self.handle(event) ?? event
            }
        }
    }

    private func stopRecording() {
        let wasRecording = isRecording
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        eventTap?.stop()
        eventTap = nil
        isRecording = false

        guard wasRecording else { return }
        NotificationCenter.default.post(
            name: .macClippyHotKeyRecordingChanged,
            object: nil,
            userInfo: [MacClippyHotKeyNotificationUserInfo.isActive: false]
        )
    }

    private func handleCapturedEvent(_ notification: Notification) {
        guard isRecording,
              let keyCodeNumber = notification.userInfo?[MacClippyHotKeyNotificationUserInfo.keyCode] as? NSNumber,
              let modifierFlagsNumber = notification.userInfo?[MacClippyHotKeyNotificationUserInfo.modifierFlags] as? NSNumber else {
            return
        }

        let keyCode = UInt16(keyCodeNumber.uint16Value)
        let modifiers = cocoaModifiers(for: CGEventFlags(rawValue: modifierFlagsNumber.uint64Value))
        handle(keyCode: keyCode, modifiers: modifiers)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let consumed = handle(keyCode: UInt16(event.keyCode), modifiers: modifiers)
        return consumed ? nil : event
    }

    @discardableResult
    private func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        if keyCode == 53, modifiers.isEmpty {
            stopRecording()
            return true
        }

        guard !isModifierKeyCode(keyCode) else { return false }
        guard !modifiers.isEmpty else { return false }

        let newDescriptor = MacClippyGlobalHotKeyDescriptor(
            keyCode: UInt32(keyCode),
            modifiers: carbonModifiers(for: modifiers)
        )
        stopRecording()
        MacClippyGlobalHotKeyDescriptor.save(newDescriptor)
        descriptor = newDescriptor
        onChange(newDescriptor)
        return true
    }

    private func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        [
            UInt16(kVK_Command), UInt16(kVK_RightCommand),
            UInt16(kVK_Shift), UInt16(kVK_RightShift),
            UInt16(kVK_Option), UInt16(kVK_RightOption),
            UInt16(kVK_Control), UInt16(kVK_RightControl)
        ].contains(keyCode)
    }

    private func carbonModifiers(for modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func cocoaModifiers(for flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }
}

private final class MacClippyHotKeyEventTap {
    private static let eventsOfInterest: CGEventMask = 1 << CGEventType.keyDown.rawValue

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() -> Bool {
        guard eventTap == nil else { return true }

        if !CGPreflightListenEventAccess(), !CGRequestListenEventAccess() {
            return false
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<MacClippyHotKeyEventTap>.fromOpaque(userInfo).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventsOfInterest,
            callback: callback,
            userInfo: context
        ) else {
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            return false
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        self.eventTap = eventTap
        runLoopSource = source
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    deinit {
        stop()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return nil
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        NotificationCenter.default.post(
            name: .macClippyHotKeyRecordingEvent,
            object: nil,
            userInfo: [
                MacClippyHotKeyNotificationUserInfo.keyCode: NSNumber(value: event.getIntegerValueField(.keyboardEventKeycode)),
                MacClippyHotKeyNotificationUserInfo.modifierFlags: NSNumber(value: event.flags.rawValue)
            ]
        )
        if event.flags.isDisjoint(with: [.maskCommand, .maskAlternate, .maskControl, .maskShift]),
           event.getIntegerValueField(.keyboardEventKeycode) != 53 {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }
}

private extension MacClippyGlobalHotKeyDescriptor {
    var symbolicDisplay: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + MacClippyHotKeyKeyName.display(for: keyCode)
    }
}

private enum MacClippyHotKeyKeyName {
    static func display(for keyCode: UInt32) -> String {
        switch keyCode {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 31: "O"
        case 32: "U"
        case 34: "I"
        case 35: "P"
        case 37: "L"
        case 38: "J"
        case 40: "K"
        case 45: "N"
        case 46: "M"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 23: "5"
        case 22: "6"
        case 26: "7"
        case 28: "8"
        case 25: "9"
        case 29: "0"
        case 49: "Space"
        case 36: "Return"
        case 48: "Tab"
        case 51: "Delete"
        case 53: "Escape"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        case 122: "F1"
        case 120: "F2"
        case 99: "F3"
        case 118: "F4"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 100: "F8"
        case 101: "F9"
        case 109: "F10"
        case 103: "F11"
        case 111: "F12"
        default: "Key \(keyCode)"
        }
    }
}
