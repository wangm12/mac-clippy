import Carbon.HIToolbox
import Foundation

public enum MacClippyGlobalHotKeyRole: Sendable, Equatable {
    case clipboardDock
    case ignoreNextCopy

    public var carbonHotKeyID: UInt32 {
        switch self {
        case .clipboardDock: 1
        case .ignoreNextCopy: 2
        }
    }

    fileprivate var keyCodeKey: String {
        switch self {
        case .clipboardDock:
            return "com.macallyouneed.macclippy.hotkey.keyCode"
        case .ignoreNextCopy:
            return "com.macallyouneed.macclippy.hotkey.ignoreNext.keyCode"
        }
    }

    fileprivate var modifiersKey: String {
        switch self {
        case .clipboardDock:
            return "com.macallyouneed.macclippy.hotkey.modifiers"
        case .ignoreNextCopy:
            return "com.macallyouneed.macclippy.hotkey.ignoreNext.modifiers"
        }
    }

    fileprivate var defaultDescriptor: MacClippyGlobalHotKeyDescriptor {
        switch self {
        case .clipboardDock:
            return .defaultClipboard
        case .ignoreNextCopy:
            return .defaultIgnoreNextCopy
        }
    }
}

public struct MacClippyGlobalHotKeyDescriptor: Equatable, Sendable {
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

    public static let defaultIgnoreNextCopy = Self(
        keyCode: UInt32(kVK_ANSI_C),
        modifiers: UInt32(cmdKey) | UInt32(optionKey) | UInt32(shiftKey)
    )

    public static func save(
        _ descriptor: Self,
        to defaults: UserDefaults = .standard,
        role: MacClippyGlobalHotKeyRole = .clipboardDock
    ) {
        defaults.set(Int(descriptor.keyCode), forKey: role.keyCodeKey)
        defaults.set(Int(descriptor.modifiers), forKey: role.modifiersKey)
    }

    public static func load(
        from defaults: UserDefaults = .standard,
        role: MacClippyGlobalHotKeyRole = .clipboardDock
    ) -> Self {
        guard defaults.object(forKey: role.keyCodeKey) != nil,
              defaults.object(forKey: role.modifiersKey) != nil else {
            return role.defaultDescriptor
        }
        return Self(
            keyCode: UInt32(defaults.integer(forKey: role.keyCodeKey)),
            modifiers: UInt32(defaults.integer(forKey: role.modifiersKey))
        )
    }
}

public enum MacClippyGlobalHotKeyError: Error, Equatable, LocalizedError, Sendable {
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

@MainActor
public final class MacClippyGlobalHotKey {
    private static let eventSignature = OSType(0x4D43_4C50)
    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
        let hotKey = Unmanaged<MacClippyGlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        return hotKey.handle(event)
    }

    private var descriptor: MacClippyGlobalHotKeyDescriptor
    private let eventHotKeyID: EventHotKeyID
    private let callback: @MainActor @Sendable () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    public var isRegistered: Bool {
        hotKeyRef != nil && eventHandlerRef != nil
    }

    public init(
        descriptor: MacClippyGlobalHotKeyDescriptor,
        role: MacClippyGlobalHotKeyRole = .clipboardDock,
        callback: @escaping @MainActor @Sendable () -> Void
    ) {
        self.descriptor = descriptor
        self.eventHotKeyID = EventHotKeyID(signature: Self.eventSignature, id: role.carbonHotKeyID)
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
            eventHotKeyID,
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

    private nonisolated func handle(_ event: EventRef) -> OSStatus {
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
        switch MacClippyHotKeyRegistrationPolicy.eventDisposition(
            parameterSucceeded: parameterStatus == noErr,
            receivedSignature: receivedID.signature,
            receivedID: receivedID.id,
            expectedSignature: eventHotKeyID.signature,
            expectedID: eventHotKeyID.id
        ) {
        case .notHandled:
            return OSStatus(eventNotHandledErr)
        case .handled:
            break
        }

        DispatchQueue.main.async { @MainActor [weak self] in
            guard let self, self.hotKeyRef != nil else { return }
            self.callback()
        }
        return noErr
    }

}
