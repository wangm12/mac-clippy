import Carbon.HIToolbox
import Foundation

public struct MacClippyGlobalHotKeyDescriptor: Equatable, Sendable {
    private static let keyCodeKey = "com.macallyouneed.macclippy.hotkey.keyCode"
    private static let modifiersKey = "com.macallyouneed.macclippy.hotkey.modifiers"

    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let defaultClipboard = Self(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey) | UInt32(shiftKey)
    )

    public static func save(_ descriptor: Self, to defaults: UserDefaults = .standard) {
        defaults.set(Int(descriptor.keyCode), forKey: keyCodeKey)
        defaults.set(Int(descriptor.modifiers), forKey: modifiersKey)
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard defaults.object(forKey: keyCodeKey) != nil,
              defaults.object(forKey: modifiersKey) != nil else {
            return .defaultClipboard
        }
        return Self(
            keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
            modifiers: UInt32(defaults.integer(forKey: modifiersKey))
        )
    }
}

public enum MacClippyGlobalHotKeyError: Error, Equatable, LocalizedError {
    case eventHandlerInstallationFailed(OSStatus)
    case registrationFailed(OSStatus)
    case registrationRollbackFailed

    public var errorDescription: String? {
        switch self {
        case let .eventHandlerInstallationFailed(status):
            "The global hotkey event handler could not be installed (status \(status))."
        case let .registrationFailed(status):
            "The global hotkey could not be registered (status \(status))."
        case .registrationRollbackFailed:
            "The global hotkey could not be updated and the previous shortcut could not be restored."
        }
    }
}

public final class MacClippyGlobalHotKey {
    private static let eventHotKeyID = EventHotKeyID(signature: OSType(0x4D43_4C50), id: 1)
    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
        let hotKey = Unmanaged<MacClippyGlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        return hotKey.handle(event)
    }

    private var descriptor: MacClippyGlobalHotKeyDescriptor
    private let callback: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    public var isRegistered: Bool {
        hotKeyRef != nil && eventHandlerRef != nil
    }

    public init(
        descriptor: MacClippyGlobalHotKeyDescriptor,
        callback: @escaping () -> Void
    ) {
        self.descriptor = descriptor
        self.callback = callback
    }

    public func register() throws {
        guard hotKeyRef == nil, eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installedHandler: EventHandlerRef?
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedHandler
        )
        guard installStatus == noErr, let installedHandler else {
            throw MacClippyGlobalHotKeyError.eventHandlerInstallationFailed(installStatus)
        }
        eventHandlerRef = installedHandler

        var registeredHotKey: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            descriptor.keyCode,
            descriptor.modifiers,
            Self.eventHotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard registrationStatus == noErr, let registeredHotKey else {
            unregister()
            throw MacClippyGlobalHotKeyError.registrationFailed(registrationStatus)
        }
        hotKeyRef = registeredHotKey
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        hotKeyRef = nil
        eventHandlerRef = nil
    }

    public func update(to newDescriptor: MacClippyGlobalHotKeyDescriptor) throws {
        let previousDescriptor = descriptor
        let wasRegistered = isRegistered
        unregister()
        descriptor = newDescriptor
        do {
            try register()
        } catch {
            // Treat a descriptor update as a transaction. The settings UI
            // persists the requested value before this synchronous Carbon
            // call runs, so restore the in-memory registration on failure;
            // the app delegate restores the persisted value as well.
            descriptor = previousDescriptor
            if wasRegistered {
                do {
                    try register()
                } catch {
                    throw MacClippyGlobalHotKeyError.registrationRollbackFailed
                }
            }
            throw error
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var receivedID = EventHotKeyID()
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedID
        )
        guard parameterStatus == noErr,
              receivedID.signature == Self.eventHotKeyID.signature,
              receivedID.id == Self.eventHotKeyID.id else {
            return noErr
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.hotKeyRef != nil else { return }
            self.callback()
        }
        return noErr
    }

    deinit {
        unregister()
    }
}
