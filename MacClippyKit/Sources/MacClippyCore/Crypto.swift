import CryptoKit
import Foundation
import Security

public struct MacClippyEnvelope: Sendable, Equatable {
    public let combined: Data

    public init(combined: Data) {
        self.combined = combined
    }
}

public enum MacClippyCipherError: Error, Equatable, Sendable {
    case invalidEnvelope
    case sealFailed
    case openFailed
}

public enum MacClippyCipher {
    public static func seal(_ plaintext: Data, with key: SymmetricKey) throws -> MacClippyEnvelope {
        do {
            let box = try AES.GCM.seal(plaintext, using: key)
            guard let combined = box.combined else { throw MacClippyCipherError.sealFailed }
            return MacClippyEnvelope(combined: combined)
        } catch let error as MacClippyCipherError {
            throw error
        } catch {
            throw MacClippyCipherError.sealFailed
        }
    }

    public static func open(_ envelope: MacClippyEnvelope, with key: SymmetricKey) throws -> Data {
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: envelope.combined)
        } catch {
            // Parsing does not depend on the key. This is safe to classify as
            // a malformed stored envelope, unlike authentication failure
            // below, which can also mean the device key is wrong.
            throw MacClippyCipherError.invalidEnvelope
        }
        do {
            return try AES.GCM.open(box, using: key)
        } catch {
            // Do not collapse authentication failure into per-record
            // corruption: a wrong or unavailable key would otherwise make
            // healthy history look empty and get silently skipped.
            throw MacClippyCipherError.openFailed
        }
    }
}

public typealias Cipher = MacClippyCipher
public typealias Envelope = MacClippyEnvelope

public protocol MacClippyKeychainBackend: AnyObject {
    func get(_ account: String) throws -> Data?
    func set(_ data: Data, for account: String) throws
    func delete(_ account: String) throws
}

public enum MacClippyKeychainError: Error, Sendable {
    case read(OSStatus)
    case write(OSStatus)
    case delete(OSStatus)
    case missingKey
}

public final class MacClippySystemKeychain: MacClippyKeychainBackend {
    public static let service = "com.macallyouneed.macclippy.device-key"
    private let service: String

    public init(service: String = MacClippySystemKeychain.service) {
        self.service = service
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func get(_ account: String) throws -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MacClippyKeychainError.read(status)
        }
        return data
    }

    public func set(_ data: Data, for account: String) throws {
        try delete(account)
        var request = query(account: account)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        request[kSecValueData as String] = data
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else { throw MacClippyKeychainError.write(status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MacClippyKeychainError.delete(status)
        }
    }
}

public final class MacClippyInMemoryKeychain: MacClippyKeychainBackend {
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func get(_ account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    public func set(_ data: Data, for account: String) throws {
        lock.lock()
        values[account] = data
        lock.unlock()
    }

    public func delete(_ account: String) throws {
        lock.lock()
        values.removeValue(forKey: account)
        lock.unlock()
    }
}

public typealias KeychainBackend = MacClippyKeychainBackend
public typealias InMemoryKeychain = MacClippyInMemoryKeychain

public final class MacClippyDeviceKey {
    public static let account = "macclippy-device-key-v1"
    private static let lock = NSLock()
    private let keychain: MacClippyKeychainBackend

    public init(keychain: MacClippyKeychainBackend) {
        self.keychain = keychain
    }

    public func deviceKey(requireExistingStorage: Bool = false) throws -> SymmetricKey {
        if let data = try keychain.get(Self.account) { return SymmetricKey(data: data) }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let data = try keychain.get(Self.account) { return SymmetricKey(data: data) }
        guard !requireExistingStorage else { throw MacClippyKeychainError.missingKey }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try keychain.set(data, for: Self.account)
        guard let stored = try keychain.get(Self.account) else { throw MacClippyKeychainError.missingKey }
        return SymmetricKey(data: stored)
    }
}
