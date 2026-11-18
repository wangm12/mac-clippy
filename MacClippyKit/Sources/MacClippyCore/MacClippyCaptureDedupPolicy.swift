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
    public let itemIndex: Int
    public let uti: String
    public let payloadState: String
    public let payloadBytes: Data?

    public init(itemIndex: Int = 0, uti: String, payloadState: String, payloadBytes: Data?) {
        self.itemIndex = itemIndex
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
    public struct StreamHasher {
        private var hasher = SHA256()
        private let isMultiItem: Bool

        public init(
            primary: MacClippyCaptureDedupPrimary,
            representationCount: Int,
            isMultiItem: Bool
        ) {
            self.isMultiItem = isMultiItem
            MacClippyCaptureDedupPolicy.append(&hasher, isMultiItem ? "v2-items" : "v1")
            MacClippyCaptureDedupPolicy.append(&hasher, primary)
            MacClippyCaptureDedupPolicy.appendCount(&hasher, representationCount)
        }

        public mutating func appendRepresentation(
            itemIndex: Int = 0,
            uti: String,
            payloadState: String,
            payloadBytes: Data?
        ) {
            if isMultiItem {
                MacClippyCaptureDedupPolicy.append(&hasher, UInt64(itemIndex))
            }
            MacClippyCaptureDedupPolicy.append(&hasher, uti)
            MacClippyCaptureDedupPolicy.append(&hasher, payloadState)
            MacClippyCaptureDedupPolicy.append(&hasher, payloadBytes ?? Data())
        }

        public func finalize() -> String {
            hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    public static func contentHash(
        primary: MacClippyCaptureDedupPrimary,
        representations: [MacClippyCaptureDedupRepresentation]
    ) -> String {
        let isMultiItem = representations.contains { $0.itemIndex != 0 }
        var stream = StreamHasher(
            primary: primary,
            representationCount: representations.count,
            isMultiItem: isMultiItem
        )
        for representation in representations {
            stream.appendRepresentation(
                itemIndex: representation.itemIndex,
                uti: representation.uti,
                payloadState: representation.payloadState,
                payloadBytes: representation.payloadBytes
            )
        }
        return stream.finalize()
    }

    /// AES-GCM combined box is nonce (12) + ciphertext + tag (16).
    public static let minimumSealedEnvelopeByteCount = 28

    /// Hash match plus intact metadata is enough to bump frequency. Tiny or
    /// incomplete rows still open the envelope so a corrupt duplicate can
    /// insert a fresh row — `Data([1,2,3])` stays on the decrypt path.
    public static func canSkipEnvelopeOpen(
        recordID: String?,
        contentKind: String?,
        preview: String?,
        envelopeByteCount: Int
    ) -> Bool {
        guard let recordID, RecordID(rawValue: recordID) != nil else { return false }
        guard let contentKind, MacClippyContentKind(rawValue: contentKind) != nil else { return false }
        guard let preview else { return false }
        if preview.isEmpty && contentKind != MacClippyContentKind.html.rawValue {
            return false
        }
        return envelopeByteCount >= minimumSealedEnvelopeByteCount
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
