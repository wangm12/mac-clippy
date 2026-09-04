import CryptoKit
import Foundation

public enum MacClippyCaptureDedupPrimary: Equatable, Sendable {
    case text(String)
    case rtf(Data)
    case html(String)
    case image(Data, width: Int, height: Int)
    case files([String])
    case none
}

public struct MacClippyCaptureDedupRepresentation: Equatable, Sendable {
    public let uti: String
    public let payloadState: String
    public let payloadBytes: Data?

    public init(uti: String, payloadState: String, payloadBytes: Data?) {
        self.uti = uti
        self.payloadState = payloadState
        self.payloadBytes = payloadBytes
    }
}

public struct MacClippyCapturePersistResult: Equatable, Sendable {
    public let meta: ClipboardItemMeta
    public let reusedExisting: Bool

    public init(meta: ClipboardItemMeta, reusedExisting: Bool) {
        self.meta = meta
        self.reusedExisting = reusedExisting
    }
}

/// Stable SHA-256 of the captured payload so an identical copy can bump
/// `frequency` / `lastAccessed` instead of writing a new encrypted row.
public enum MacClippyCaptureDedupPolicy {
    public static func contentHash(
        primary: MacClippyCaptureDedupPrimary,
        representations: [MacClippyCaptureDedupRepresentation]
    ) -> String {
        var hasher = SHA256()
        append(&hasher, "v1")
        append(&hasher, primary)
        appendCount(&hasher, representations.count)
        for representation in representations {
            append(&hasher, representation.uti)
            append(&hasher, representation.payloadState)
            append(&hasher, representation.payloadBytes ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ hasher: inout SHA256, _ primary: MacClippyCaptureDedupPrimary) {
        switch primary {
        case let .text(value):
            append(&hasher, "text")
            append(&hasher, value)
        case let .rtf(data):
            append(&hasher, "rtf")
            append(&hasher, data)
        case let .html(value):
            append(&hasher, "html")
            append(&hasher, value)
        case let .image(data, width, height):
            append(&hasher, "image")
            append(&hasher, UInt64(width))
            append(&hasher, UInt64(height))
            append(&hasher, data)
        case let .files(paths):
            append(&hasher, "files")
            appendCount(&hasher, paths.count)
            for path in paths {
                append(&hasher, path)
            }
        case .none:
            append(&hasher, "none")
        }
    }

    private static func append(_ hasher: inout SHA256, _ string: String) {
        append(&hasher, Data(string.utf8))
    }

    private static func append(_ hasher: inout SHA256, _ data: Data) {
        append(&hasher, UInt64(data.count))
        hasher.update(data: data)
    }

    private static func append(_ hasher: inout SHA256, _ value: UInt64) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { hasher.update(data: Data($0)) }
    }

    private static func appendCount(_ hasher: inout SHA256, _ count: Int) {
        append(&hasher, UInt64(count))
    }
}
