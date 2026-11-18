import CommonCrypto
import CryptoKit
import Foundation
import Security

public struct MacClippyBackupArchiveOptions {
    public let passphrase: String
    public let pbkdf2Iterations: UInt32
    public let overwriteExisting: Bool
    public let now: Date
    public let shouldContinue: () -> Bool
    public let fileManager: FileManager

    public init(
        passphrase: String,
        pbkdf2Iterations: UInt32 = MacClippyBackupArchive.defaultPBKDF2Iterations,
        overwriteExisting: Bool = false,
        now: Date = Date(),
        shouldContinue: @escaping () -> Bool = { true },
        fileManager: FileManager = .default
    ) {
        self.passphrase = passphrase
        self.pbkdf2Iterations = pbkdf2Iterations
        self.overwriteExisting = overwriteExisting
        self.now = now
        self.shouldContinue = shouldContinue
        self.fileManager = fileManager
    }
}

public enum MacClippyBackupArchive {
    public static let magic = Data("MCBK\0\u{03}".utf8)
    public static let defaultPBKDF2Iterations: UInt32 = 600_000
    public static let minimumPBKDF2Iterations: UInt32 = 10_000
    public static let maxPBKDF2Iterations: UInt32 = 5_000_000
    public static let streamingChunkSize = 4 * 1024 * 1024
    static let archiveIDLength = 16
    static let saltLength = 32
    static let maxFileEntryPathBytes = 4_096
    private static let fileCopySliceBytes = 256 * 1024

    public static func pack(
        snapshotDirectory: URL,
        sourceKey: SymmetricKey,
        to destinationArchiveURL: URL,
        options: MacClippyBackupArchiveOptions
    ) throws {
        guard !options.passphrase.isEmpty else { throw MacClippyBackupError.passphraseRequired }
        guard options.pbkdf2Iterations >= minimumPBKDF2Iterations,
              options.pbkdf2Iterations <= maxPBKDF2Iterations else {
            throw MacClippyBackupError.corruptedArchive
        }
        let fileManager = options.fileManager
        if !options.overwriteExisting, fileManager.fileExists(atPath: destinationArchiveURL.path) {
            throw MacClippyBackupError.destinationExists
        }
        let entries = try collectedRelativeFiles(
            in: snapshotDirectory,
            fileManager: fileManager,
            shouldContinue: options.shouldContinue
        )
        let parentURL = destinationArchiveURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        let tempArchiveURL = parentURL.appendingPathComponent(".macclippy-archive-\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: tempArchiveURL.path, contents: nil) else {
            throw MacClippyBackupError.corruptedArchive
        }
        defer { try? fileManager.removeItem(at: tempArchiveURL) }
        try writeArchive(
            tempArchiveURL: tempArchiveURL,
            snapshotDirectory: snapshotDirectory,
            entries: entries,
            sourceKey: sourceKey,
            options: options
        )
        try publishTempArchive(
            tempArchiveURL,
            to: destinationArchiveURL,
            overwrite: options.overwriteExisting,
            fileManager: fileManager
        )
    }

    public static func unpack(
        archiveURL: URL,
        to destinationDirectory: URL,
        passphrase: String,
        fileManager: FileManager = .default,
        shouldContinue: () -> Bool = { true }
    ) throws -> SymmetricKey {
        guard !passphrase.isEmpty else { throw MacClippyBackupError.passphraseRequired }
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }
        let header = try readAndAuthenticateHeader(from: handle, passphrase: passphrase)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        var decoder = MacClippyBackupArchiveEntryDecoder(
            destinationDirectory: destinationDirectory,
            fileManager: fileManager
        )
        try streamDecryptBody(
            from: handle,
            header: header,
            decoder: &decoder,
            shouldContinue: shouldContinue
        )
        try decoder.finish()
        return header.sourceKey
    }
}

struct ArchiveHeader {
    let archiveID: Data
    let archiveKey: SymmetricKey
    let sourceKey: SymmetricKey
}

private struct ArchiveChunkWriter {
    let handle: FileHandle
    let archiveID: Data
    let archiveKey: SymmetricKey
    var buffer = Data()
    var pendingSealedChunk: Data?
    var chunkIndex: UInt64 = 0

    mutating func append(_ data: Data) throws {
        var offset = data.startIndex
        while offset < data.endIndex {
            let room = MacClippyBackupArchive.streamingChunkSize - buffer.count
            if room == 0 {
                try flushBufferAsNonFinal()
                continue
            }
            let take = min(room, data.endIndex - offset)
            buffer.append(data[offset..<(offset + take)])
            offset += take
            if buffer.count == MacClippyBackupArchive.streamingChunkSize {
                try flushBufferAsNonFinal()
            }
        }
    }

    private mutating func flushBufferAsNonFinal() throws {
        if let pending = pendingSealedChunk {
            try writeChunkFrame(combined: pending, isFinal: 0)
            chunkIndex += 1
        }
        let aad = MacClippyBackupArchive.chunkAAD(archiveID: archiveID, index: chunkIndex, isFinal: 0)
        pendingSealedChunk = try sealChunk(buffer, using: archiveKey, authenticating: aad)
        buffer.removeAll(keepingCapacity: true)
    }

    mutating func finish() throws {
        if let pending = pendingSealedChunk {
            let isPendingFinal: UInt8 = buffer.isEmpty ? 1 : 0
            try writeChunkFrame(combined: pending, isFinal: isPendingFinal)
            chunkIndex += 1
            pendingSealedChunk = nil
            if isPendingFinal == 1 { return }
        }
        let aad = MacClippyBackupArchive.chunkAAD(archiveID: archiveID, index: chunkIndex, isFinal: 1)
        let finalCombined = try sealChunk(buffer, using: archiveKey, authenticating: aad)
        try writeChunkFrame(combined: finalCombined, isFinal: 1)
    }

    private func sealChunk(
        _ plaintext: Data,
        using key: SymmetricKey,
        authenticating aad: Data
    ) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined else {
            throw MacClippyBackupError.corruptedArchive
        }
        return combined
    }

    private func writeChunkFrame(combined: Data, isFinal: UInt8) throws {
        try handle.write(contentsOf: MacClippyBackupArchive.bigEndianBytes(UInt32(combined.count)))
        try handle.write(contentsOf: Data([isFinal]))
        try handle.write(contentsOf: combined)
    }
}

extension MacClippyBackupArchive {
    private static func writeArchive(
        tempArchiveURL: URL,
        snapshotDirectory: URL,
        entries: [String],
        sourceKey: SymmetricKey,
        options: MacClippyBackupArchiveOptions
    ) throws {
        let handle = try FileHandle(forWritingTo: tempArchiveURL)
        defer { try? handle.close() }
        let archiveID = try randomBytes(count: archiveIDLength)
        let salt = try randomBytes(count: saltLength)
        let iterations = options.pbkdf2Iterations
        let archiveKey = try deriveArchiveKey(passphrase: options.passphrase, salt: salt, iterations: iterations)
        let headerAAD = headerAADBytes(archiveID: archiveID, iterations: iterations, salt: salt)
        let sourceKeyData = sourceKey.withUnsafeBytes { Data($0) }
        guard let wrappedKey = try AES.GCM.seal(
            sourceKeyData,
            using: archiveKey,
            authenticating: headerAAD
        ).combined else {
            throw MacClippyBackupError.corruptedArchive
        }
        try handle.write(contentsOf: headerAAD)
        try handle.write(contentsOf: bigEndianBytes(UInt16(wrappedKey.count)))
        try handle.write(contentsOf: wrappedKey)

        var writer = ArchiveChunkWriter(handle: handle, archiveID: archiveID, archiveKey: archiveKey)
        for relativePath in entries {
            try ensureContinues(options.shouldContinue)
            try writeFileEntry(
                relativePath: relativePath,
                snapshotDirectory: snapshotDirectory,
                writer: &writer,
                shouldContinue: options.shouldContinue
            )
        }
        try writer.append(bigEndianBytes(UInt16(0)))
        try writer.finish()
        try handle.synchronize()
    }

    private static func writeFileEntry(
        relativePath: String,
        snapshotDirectory: URL,
        writer: inout ArchiveChunkWriter,
        shouldContinue: () -> Bool
    ) throws {
        let pathData = Data(relativePath.utf8)
        guard pathData.count <= maxFileEntryPathBytes else { throw MacClippyBackupError.corruptedArchive }
        let fileURL = snapshotDirectory.appendingPathComponent(relativePath)
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, let fileSize = values.fileSize else {
            throw MacClippyBackupError.corruptedArchive
        }
        try writer.append(bigEndianBytes(UInt16(pathData.count)))
        try writer.append(pathData)
        try writer.append(bigEndianBytes(UInt64(fileSize)))
        let inputHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? inputHandle.close() }
        var remaining = UInt64(fileSize)
        while remaining > 0 {
            try ensureContinues(shouldContinue)
            let count = Int(min(UInt64(fileCopySliceBytes), remaining))
            guard let slice = try inputHandle.read(upToCount: count), !slice.isEmpty else {
                throw MacClippyBackupError.corruptedArchive
            }
            try writer.append(slice)
            remaining -= UInt64(slice.count)
        }
    }

    private static func collectedRelativeFiles(
        in rootURL: URL,
        fileManager: FileManager,
        shouldContinue: () -> Bool
    ) throws -> [String] {
        let rootStandardized = rootURL.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw MacClippyBackupError.missingComponent(rootURL.lastPathComponent)
        }
        var results: [String] = []
        for case let url as URL in enumerator {
            try ensureContinues(shouldContinue)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw MacClippyBackupError.corruptedArchive }
            guard values.isRegularFile == true else { continue }
            let standardized = url.standardizedFileURL.path
            let prefix = rootStandardized + "/"
            guard standardized.hasPrefix(prefix) else { continue }
            results.append(String(standardized.dropFirst(prefix.count)))
        }
        return results.sorted()
    }

    private static func publishTempArchive(
        _ tempArchiveURL: URL,
        to destinationURL: URL,
        overwrite: Bool,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            guard overwrite else { throw MacClippyBackupError.destinationExists }
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempArchiveURL)
        } else {
            try fileManager.moveItem(at: tempArchiveURL, to: destinationURL)
        }
    }

    static func ensureContinues(_ shouldContinue: () -> Bool) throws {
        guard shouldContinue() else { throw CancellationError() }
    }
}
