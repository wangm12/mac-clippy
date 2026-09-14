import CryptoKit
import Foundation

/// Persists downsampled card thumbnails beside the blob store so a later
/// dock open can skip ImageIO on the original payload. Bytes are sealed with
/// the device key; this directory is not scanned as BlobStore orphans.
public final class MacClippyThumbnailDiskCache: @unchecked Sendable {
    private let directoryURL: URL
    private let key: SymmetricKey
    private let fileManager: FileManager
    private let byteLimit: Int

    public init(
        directoryURL: URL,
        key: SymmetricKey,
        fileManager: FileManager = .default,
        byteLimit: Int = MacClippyThumbnailCachePolicy.diskByteLimit
    ) {
        self.directoryURL = directoryURL
        self.key = key
        self.fileManager = fileManager
        self.byteLimit = byteLimit
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
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        let files = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var entries: [(url: URL, bytes: Int, modified: Date)] = files.compactMap { file in
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let bytes = values?.fileSize else { return nil }
            return (file, bytes, values?.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.bytes }
        guard MacClippyThumbnailCachePolicy.shouldEvictOldestDiskEntries(
            currentBytes: total,
            limit: byteLimit
        ) else { return }
        entries.sort { $0.modified < $1.modified }
        for entry in entries {
            guard MacClippyThumbnailCachePolicy.shouldEvictOldestDiskEntries(
                currentBytes: total,
                limit: byteLimit
            ) else { return }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.bytes
        }
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
