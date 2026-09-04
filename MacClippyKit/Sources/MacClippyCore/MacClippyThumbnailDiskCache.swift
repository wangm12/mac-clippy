import CryptoKit
import Foundation

/// Persists downsampled card thumbnails beside the blob store so a later
/// dock open can skip ImageIO on the original payload. Bytes are sealed with
/// the device key; this directory is not scanned as BlobStore orphans.
public final class MacClippyThumbnailDiskCache: @unchecked Sendable {
    private let directoryURL: URL
    private let key: SymmetricKey
    private let fileManager: FileManager

    public init(
        directoryURL: URL,
        key: SymmetricKey,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.key = key
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public func pngData(id: RecordID, maxPixelSize: Int) -> Data? {
        let url = fileURL(id: id, maxPixelSize: maxPixelSize)
        guard let envelope = try? Data(contentsOf: url) else { return nil }
        return try? MacClippyCipher.open(MacClippyEnvelope(combined: envelope), with: key)
    }

    public func store(_ png: Data, id: RecordID, maxPixelSize: Int) throws {
        let url = fileURL(id: id, maxPixelSize: maxPixelSize)
        let envelope = try MacClippyCipher.seal(png, with: key)
        try envelope.combined.write(to: url, options: .atomic)
    }

    public func remove(id: RecordID, maxPixelSize: Int = MacClippyThumbnailCachePolicy.defaultMaxPixelSize) {
        let url = fileURL(id: id, maxPixelSize: maxPixelSize)
        try? fileManager.removeItem(at: url)
    }

    private func fileURL(id: RecordID, maxPixelSize: Int) -> URL {
        directoryURL.appendingPathComponent(
            MacClippyThumbnailCachePolicy.fileName(
                recordID: id.rawValue,
                maxPixelSize: maxPixelSize
            )
        )
    }
}
