import CryptoKit
import Foundation

public enum MacClippyBlobError: Error {
    case invalidIdentifier
    case missingBlob
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
        let url = try url(for: id)
        guard fileManager.fileExists(atPath: url.path) else { throw MacClippyBlobError.missingBlob }
        return try MacClippyCipher.open(MacClippyEnvelope(combined: Data(contentsOf: url)), with: key)
    }

    public func delete(id: String) throws {
        let url = try url(for: id)
        do {
            try fileManager.removeItem(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        }
    }

    public func contains(id: String) -> Bool {
        guard let url = try? url(for: id) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    public func byteSize(id: String) -> Int {
        guard let url = try? url(for: id),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return 0 }
        return size
    }

    public func encryptedURL(id: String) -> URL {
        (try? url(for: id)) ?? rootURL
    }

    private func url(for id: String) throws -> URL {
        guard Self.isSafeIdentifier(id) else { throw MacClippyBlobError.invalidIdentifier }
        return rootURL.appendingPathComponent(id + ".bin", isDirectory: false).standardizedFileURL
    }

    private static func isSafeIdentifier(_ id: String) -> Bool {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\") else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}

public typealias BlobStore = MacClippyBlobStore
