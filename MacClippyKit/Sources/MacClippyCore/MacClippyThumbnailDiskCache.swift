import CryptoKit
import Foundation

/// A stored thumbnail can no longer be written after its cache is retired for
/// a restore.
public enum MacClippyThumbnailDiskCacheError: Error, Equatable {
    case retired
}

/// Persists downsampled card thumbnails beside the blob store so a later
/// dock open can skip ImageIO on the original payload. Bytes are sealed with
/// the device key; this directory is not scanned as BlobStore orphans.
public final class MacClippyThumbnailDiskCache: @unchecked Sendable {
    private let directoryURL: URL
    private let key: SymmetricKey
    private let fileManager: FileManager
    private let byteLimit: Int
    private let testHooks: MacClippyThumbnailDiskCacheTestHooks?

    // The condition protects only admission and the active I/O count. It is
    // never held while FileManager or Data touches the cache directory.
    private let lifetimeCondition = NSCondition()
    private var isRetired = false
    private var activeIOCount = 0

    public convenience init(
        directoryURL: URL,
        key: SymmetricKey,
        fileManager: FileManager = .default,
        byteLimit: Int = MacClippyThumbnailCachePolicy.diskByteLimit
    ) {
        self.init(
            directoryURL: directoryURL,
            key: key,
            fileManager: fileManager,
            byteLimit: byteLimit,
            testHooks: nil
        )
    }

    init(
        directoryURL: URL,
        key: SymmetricKey,
        fileManager: FileManager = .default,
        byteLimit: Int = MacClippyThumbnailCachePolicy.diskByteLimit,
        testHooks: MacClippyThumbnailDiskCacheTestHooks?
    ) {
        self.directoryURL = directoryURL
        self.key = key
        self.fileManager = fileManager
        self.byteLimit = byteLimit
        self.testHooks = testHooks
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public func pngData(id: RecordID, maxPixelSize: Int) -> Data? {
        let url = fileURL(id: id, maxPixelSize: maxPixelSize)
        let storedData: Data
        do {
            guard let read = try withIOPermit({
                testHooks?.beforeFileSystemOperation?(.read)
                return try Data(contentsOf: url)
            }) else { return nil }
            storedData = read
        } catch {
            return nil
        }
        return try? MacClippyCipher.open(MacClippyEnvelope(combined: storedData), with: key)
    }

    public func store(_ png: Data, id: RecordID, maxPixelSize: Int) throws {
        // Avoid encoding work for the common already-retired case. The permit
        // below is still the authoritative boundary if retirement races this
        // work.
        guard acceptsOperations else { throw MacClippyThumbnailDiskCacheError.retired }

        let url = fileURL(id: id, maxPixelSize: maxPixelSize)
        let envelope = try MacClippyCipher.seal(png, with: key)
        let stored = try withIOPermit {
            testHooks?.beforeFileSystemOperation?(.write)
            try envelope.combined.write(to: url, options: .atomic)
            evictIfNeededWithinCurrentPermit()
            return true
        }
        guard stored == true else { throw MacClippyThumbnailDiskCacheError.retired }
    }

    /// Removes this instance from service for a restore. Call on a background
    /// queue before replacing `directoryURL`. It rejects new filesystem work,
    /// then waits only for admitted cache I/O (never image encoding/decoding).
    /// The admission lock is not held while that I/O runs. This method is
    /// idempotent.
    public func retireForRestore() {
        precondition(!Thread.isMainThread, "Thumbnail cache retirement must run off the main thread")

        lifetimeCondition.lock()
        let newlyRetired = !isRetired
        isRetired = true
        lifetimeCondition.broadcast()
        lifetimeCondition.unlock()

        if newlyRetired {
            testHooks?.didCloseAdmission?()
        }

        lifetimeCondition.lock()
        while activeIOCount > 0 {
            lifetimeCondition.wait()
        }
        lifetimeCondition.unlock()
    }

    public func remove(id: RecordID, maxPixelSize: Int = MacClippyThumbnailCachePolicy.defaultMaxPixelSize) {
        let url = fileURL(id: id, maxPixelSize: maxPixelSize)
        _ = withIOPermit {
            testHooks?.beforeFileSystemOperation?(.remove)
            try? fileManager.removeItem(at: url)
        }
    }

    private var acceptsOperations: Bool {
        lifetimeCondition.lock()
        defer { lifetimeCondition.unlock() }
        return !isRetired
    }

    /// Grants one permit for the complete short file operation. `store`
    /// includes eviction in the same permit so it cannot be retired between
    /// its write and nested cleanup.
    private func withIOPermit<T>(_ operation: () throws -> T) rethrows -> T? {
        lifetimeCondition.lock()
        guard !isRetired else {
            lifetimeCondition.unlock()
            return nil
        }
        activeIOCount += 1
        lifetimeCondition.unlock()

        defer {
            lifetimeCondition.lock()
            activeIOCount -= 1
            if activeIOCount == 0 {
                lifetimeCondition.broadcast()
            }
            lifetimeCondition.unlock()
        }
        return try operation()
    }

    /// Must only be called inside the `store` permit, so enumeration and any
    /// eviction removals drain together with the write that triggered them.
    private func evictIfNeededWithinCurrentPermit() {
        testHooks?.beforeFileSystemOperation?(.directoryListing)
        let files = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var entries: [(url: URL, bytes: Int, modified: Date)] = files.compactMap { file in
            testHooks?.beforeFileSystemOperation?(.fileMetadata)
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
            testHooks?.beforeFileSystemOperation?(.evictionRemoval)
            try? fileManager.removeItem(at: entry.url)
            total -= entry.bytes
        }
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

// These hooks are internal and injected only by Core tests. The filesystem
// hook runs after permit admission and immediately before the indicated I/O.
struct MacClippyThumbnailDiskCacheTestHooks: Sendable {
    let beforeFileSystemOperation: (@Sendable (FileSystemOperation) -> Void)?
    let didCloseAdmission: (@Sendable () -> Void)?

    enum FileSystemOperation: Equatable, Sendable {
        case read
        case write
        case remove
        case directoryListing
        case fileMetadata
        case evictionRemoval
    }
}
