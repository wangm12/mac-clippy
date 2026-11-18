import Foundation
import MacClippyCore

struct MacClippyGoogleOAuthTokens: Codable, Sendable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    let clientID: String
    let clientSecret: String
    var accountEmail: String?
}

final class MacClippyCloudBackupKeychain: @unchecked Sendable {
    static let passphraseAccount = "macclippy-cloud-backup-passphrase-v1"
    static let googleTokensAccount = "macclippy-gdrive-oauth-tokens-v1"

    private let backend: MacClippyKeychainBackend
    private let lock = NSLock()

    init(backend: MacClippyKeychainBackend = MacClippySystemKeychain()) {
        self.backend = backend
    }

    func loadPassphrase() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? backend.get(Self.passphraseAccount),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    func savePassphrase(_ passphrase: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if passphrase.isEmpty {
            try backend.delete(Self.passphraseAccount)
        } else {
            try backend.set(Data(passphrase.utf8), for: Self.passphraseAccount)
        }
    }

    func clearPassphrase() throws {
        lock.lock()
        defer { lock.unlock() }
        try backend.delete(Self.passphraseAccount)
    }

    func loadGoogleTokens() -> MacClippyGoogleOAuthTokens? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? backend.get(Self.googleTokensAccount) else { return nil }
        return try? JSONDecoder().decode(MacClippyGoogleOAuthTokens.self, from: data)
    }

    func saveGoogleTokens(_ tokens: MacClippyGoogleOAuthTokens) throws {
        lock.lock()
        defer { lock.unlock() }
        let data = try JSONEncoder().encode(tokens)
        try backend.set(data, for: Self.googleTokensAccount)
    }

    func clearGoogleTokens() throws {
        lock.lock()
        defer { lock.unlock() }
        try backend.delete(Self.googleTokensAccount)
    }
}
