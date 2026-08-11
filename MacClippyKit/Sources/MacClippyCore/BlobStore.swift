import CryptoKit
import Foundation

public enum MacClippyBlobError: Error, Sendable {
    case invalidIdentifier
    case missingBlob
    case payloadTooLarge
}

public final class MacClippyBlobStore {
    private let rootURL: URL
    private let key: SymmetricKey
    private let fileManager: FileManager

    public init(rootURL: URL, key: SymmetricKey, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.key = key
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    @discardableResult
    public func write(_ data: Data) throws -> String {
        try write(data, id: MacClippyRecordID.generate().rawValue)
    }

    @discardableResult
    public func write(_ data: Data, id: String) throws -> String {
        let url = try url(for: id)
        let envelope = try MacClippyCipher.seal(data, with: key)
        try envelope.combined.write(to: url, options: .atomic)
        return id
    }

    public func read(id: String) throws -> Data {
        try read(id: id, maxBytes: nil)
    }

    /// Reads an authenticated Blob envelope after checking its on-disk size.
    /// The size check happens before `Data(contentsOf:)` so callers such as
    /// thumbnail loading do not allocate an unexpectedly large historical
    /// image merely to discover that it cannot be decoded cheaply.
    public func read(id: String, maxBytes: Int?) throws -> Data {
        let url = try url(for: id)
        let values = try resourceValues(for: url)
        if let maxBytes, values.fileSize ?? 0 > maxBytes + 64 {
            throw MacClippyBlobError.payloadTooLarge
        }
        return try MacClippyCipher.open(MacClippyEnvelope(combined: Data(contentsOf: url)), with: key)
    }

    public func delete(id: String) throws {
        let url = try url(for: id)
        do {
            try fileManager.removeItem(at: url)
        } catch let error as NSError where Self.isMissingFileError(error) {
            return
        }
    }

    public func contains(id: String) throws -> Bool {
        try containsChecked(id: id)
    }

    /// Throwing variant for storage maintenance and diagnostics. Only a
    /// valid identifier that is not present maps to `false`; malformed IDs
    /// and path/I/O failures remain observable errors.
    public func containsChecked(id: String) throws -> Bool {
        let url = try url(for: id)
        do {
            _ = try resourceValues(for: url)
            return true
        } catch MacClippyBlobError.missingBlob {
            return false
        }
    }

    public func byteSize(id: String) throws -> Int {
        try byteSizeChecked(id: id)
    }

    public func byteSizeChecked(id: String) throws -> Int {
        let url = try url(for: id)
        let values = try resourceValues(for: url)
        guard let size = values.fileSize else { throw MacClippyBlobError.missingBlob }
        return size
    }

    public func encryptedURL(id: String) throws -> URL {
        try encryptedURLChecked(id: id)
    }

    public func encryptedURLChecked(id: String) throws -> URL {
        try url(for: id)
    }

    /// Streams blob identifiers without materializing the directory listing.
    /// Reconciliation uses this boundary so the number of files on disk does
    /// not become a second unbounded in-memory collection.
    public func forEachID(
        shouldContinue: () -> Bool = { true },
        _ body: (String) throws -> Void
    ) throws {
        let rootValues = try rootURL.resourceValues(forKeys: [.isDirectoryKey])
        guard rootValues.isDirectory == true else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadUnknownError,
                userInfo: [NSFilePathErrorKey: rootURL.path]
            )
        }
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw enumerationError ?? NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadUnknownError,
                userInfo: [NSFilePathErrorKey: rootURL.path]
            )
        }

        for case let fileURL as URL in enumerator {
            guard shouldContinue() else { throw CancellationError() }
            guard fileURL.deletingLastPathComponent().standardizedFileURL == rootURL,
                  fileURL.pathExtension == "bin" else {
                continue
            }
            let identifier = fileURL.deletingPathExtension().lastPathComponent
            guard Self.isSafeIdentifier(identifier) else { continue }
            try body(identifier)
        }
        if let enumerationError {
            throw enumerationError
        }
    }

    private func url(for id: String) throws -> URL {
        guard Self.isSafeIdentifier(id) else { throw MacClippyBlobError.invalidIdentifier }
        return rootURL.appendingPathComponent(id + ".bin", isDirectory: false).standardizedFileURL
    }

    private func resourceValues(for url: URL) throws -> URLResourceValues {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw MacClippyBlobError.missingBlob }
            return values
        } catch let error as MacClippyBlobError {
            throw error
        } catch let error as NSError where Self.isMissingFileError(error) {
            throw MacClippyBlobError.missingBlob
        }
    }

    private static func isMissingFileError(_ error: NSError) -> Bool {
        guard error.domain == NSCocoaErrorDomain else { return false }
        return error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
    }

    private static func isSafeIdentifier(_ id: String) -> Bool {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\") else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

public typealias BlobStore = MacClippyBlobStore
