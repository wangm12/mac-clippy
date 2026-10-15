#if MACCLIPPY_E2E
import Foundation
import Darwin
import MacClippyCore

final class MacClippyE2EFileKeychain: MacClippyKeychainBackend, @unchecked Sendable {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func get(_ account: String) throws -> Data? {
        guard account == MacClippyDeviceKey.account else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw MacClippyE2EIsolationError.keyUnavailable
        }
        defer { close(descriptor) }

        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              (fileInfo.st_mode & S_IFMT) == S_IFREG,
              fileInfo.st_uid == getuid(),
              (fileInfo.st_mode & 0o777) == 0o600 else {
            throw MacClippyE2EIsolationError.keyPermissions
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            guard count > 0, data.count + count <= 32 else {
                throw MacClippyE2EIsolationError.keyUnavailable
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == 32 else { throw MacClippyE2EIsolationError.keyUnavailable }
        return data
    }

    func set(_ data: Data, for account: String) throws {
        guard account == MacClippyDeviceKey.account, data.count == 32 else {
            throw MacClippyE2EIsolationError.keyUnavailable
        }
        let descriptor = open(
            url.path,
            O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw MacClippyE2EIsolationError.keyUnavailable }
        var shouldRemoveFile = true
        defer {
            close(descriptor)
            if shouldRemoveFile { _ = unlink(url.path) }
        }
        guard fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw MacClippyE2EIsolationError.keyPermissions
        }
        let writeSucceeded = data.withUnsafeBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        guard writeSucceeded, fsync(descriptor) == 0 else {
            throw MacClippyE2EIsolationError.keyUnavailable
        }
        shouldRemoveFile = false
    }

    func delete(_ account: String) throws {
        guard account == MacClippyDeviceKey.account else { return }
        if unlink(url.path) != 0, errno != ENOENT {
            throw MacClippyE2EIsolationError.keyUnavailable
        }
    }
}
#endif
