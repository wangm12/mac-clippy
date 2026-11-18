import CommonCrypto
import CryptoKit
import Foundation
import Security

struct MacClippyBackupArchiveEntryDecoder {
    private enum Phase {
        case pathLength
        case pathBytes(expected: Int)
        case fileSize(path: String)
        case fileBody(handle: FileHandle, remaining: UInt64)
        case finished
    }

    private let destinationDirectory: URL
    private let standardizedRootPrefix: String
    private let fileManager: FileManager
    private var staging = Data()
    private var phase: Phase = .pathLength

    init(destinationDirectory: URL, fileManager: FileManager) {
        self.destinationDirectory = destinationDirectory
        self.standardizedRootPrefix = destinationDirectory.standardizedFileURL.path + "/"
        self.fileManager = fileManager
    }

    mutating func consume(_ chunk: Data) throws {
        var cursor = chunk.startIndex
        while cursor < chunk.endIndex {
            switch phase {
            case let .fileBody(handle, remaining):
                if remaining == 0 {
                    try handle.close()
                    phase = .pathLength
                    continue
                }
                let take = Int(min(UInt64(chunk.endIndex - cursor), remaining))
                try handle.write(contentsOf: chunk[cursor..<(cursor + take)])
                cursor += take
                let nextRemaining = remaining - UInt64(take)
                if nextRemaining == 0 {
                    try handle.close()
                    phase = .pathLength
                } else {
                    phase = .fileBody(handle: handle, remaining: nextRemaining)
                }
            case .pathLength, .pathBytes, .fileSize:
                staging.append(chunk[cursor])
                cursor += 1
                try advanceHeaderStateIfReady()
            case .finished:
                throw MacClippyBackupError.corruptedArchive
            }
        }
    }

    mutating func finish() throws {
        guard case .finished = phase, staging.isEmpty else {
            closeActiveHandle()
            throw MacClippyBackupError.corruptedArchive
        }
    }

    private mutating func closeActiveHandle() {
        if case let .fileBody(handle, _) = phase {
            try? handle.close()
        }
    }

    private mutating func advanceHeaderStateIfReady() throws {
        switch phase {
        case .pathLength:
            guard staging.count == 2 else { return }
            let pathLength = Int(decodeUInt16(staging))
            staging.removeAll(keepingCapacity: true)
            if pathLength == 0 {
                phase = .finished
            } else {
                guard pathLength <= MacClippyBackupArchive.maxFileEntryPathBytes else {
                    throw MacClippyBackupError.corruptedArchive
                }
                phase = .pathBytes(expected: pathLength)
            }
        case let .pathBytes(expected):
            guard staging.count == expected else { return }
            guard let path = String(data: staging, encoding: .utf8) else {
                throw MacClippyBackupError.corruptedArchive
            }
            staging.removeAll(keepingCapacity: true)
            try validateSafeRelativePath(path)
            phase = .fileSize(path: path)
        case let .fileSize(path):
            guard staging.count == 8 else { return }
            let size = decodeUInt64(staging)
            staging.removeAll(keepingCapacity: true)
            let targetURL = try verifiedDestinationURL(for: path)
            try openOutputHandle(at: targetURL, fileSize: size)
        case .fileBody, .finished:
            break
        }
    }

    private mutating func openOutputHandle(at targetURL: URL, fileSize: UInt64) throws {
        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.createFile(atPath: targetURL.path, contents: nil) else {
            throw MacClippyBackupError.corruptedArchive
        }
        let handle = try FileHandle(forWritingTo: targetURL)
        if fileSize == 0 {
            try handle.close()
            phase = .pathLength
        } else {
            phase = .fileBody(handle: handle, remaining: fileSize)
        }
    }

    private func validateSafeRelativePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\\") else {
            throw MacClippyBackupError.corruptedArchive
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw MacClippyBackupError.corruptedArchive
        }
    }

    private func verifiedDestinationURL(for relativePath: String) throws -> URL {
        let candidate = destinationDirectory.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(standardizedRootPrefix) else {
            throw MacClippyBackupError.corruptedArchive
        }
        return candidate
    }

    private func decodeUInt16(_ data: Data) -> UInt16 {
        UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
    }

    private func decodeUInt64(_ data: Data) -> UInt64 {
        var value: UInt64 = 0
        for byte in data {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }
}

extension MacClippyBackupArchive {
    static func readAndAuthenticateHeader(
        from handle: FileHandle,
        passphrase: String
    ) throws -> ArchiveHeader {
        let magicBytes = try readExact(magic.count, from: handle)
        guard magicBytes == magic else { throw MacClippyBackupError.corruptedArchive }
        let archiveID = try readExact(archiveIDLength, from: handle)
        let iterations = try readUInt32(from: handle)
        guard iterations >= minimumPBKDF2Iterations, iterations <= maxPBKDF2Iterations else {
            throw MacClippyBackupError.corruptedArchive
        }
        let salt = try readExact(saltLength, from: handle)
        let wrappedLength = Int(try readUInt16(from: handle))
        guard wrappedLength >= 28, wrappedLength <= 1_024 else { throw MacClippyBackupError.corruptedArchive }
        let wrappedCombined = try readExact(wrappedLength, from: handle)
        let headerAAD = headerAADBytes(archiveID: archiveID, iterations: iterations, salt: salt)
        let archiveKey = try deriveArchiveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        do {
            let box = try AES.GCM.SealedBox(combined: wrappedCombined)
            let keyData = try AES.GCM.open(box, using: archiveKey, authenticating: headerAAD)
            guard keyData.count == 32 else { throw MacClippyBackupError.corruptedArchive }
            return ArchiveHeader(archiveID: archiveID, archiveKey: archiveKey, sourceKey: SymmetricKey(data: keyData))
        } catch CryptoKitError.authenticationFailure {
            throw MacClippyBackupError.invalidPassphrase
        } catch let backupError as MacClippyBackupError {
            throw backupError
        } catch {
            throw MacClippyBackupError.corruptedArchive
        }
    }

    static func streamDecryptBody(
        from handle: FileHandle,
        header: ArchiveHeader,
        decoder: inout MacClippyBackupArchiveEntryDecoder,
        shouldContinue: () -> Bool
    ) throws {
        var chunkIndex: UInt64 = 0
        var sawFinal = false
        while true {
            try ensureContinues(shouldContinue)
            let lenPrefix = try readUpTo(4, from: handle)
            if lenPrefix.isEmpty { break }
            guard lenPrefix.count == 4, !sawFinal else { throw MacClippyBackupError.corruptedArchive }
            let combinedLength = Int(readUInt32(from: lenPrefix))
            let maxCombinedLength = streamingChunkSize + 1_024
            guard combinedLength >= 28, combinedLength <= maxCombinedLength else {
                throw MacClippyBackupError.corruptedArchive
            }
            let finalData = try readExact(1, from: handle)
            let isFinalByte = finalData[finalData.startIndex]
            guard isFinalByte == 0 || isFinalByte == 1 else { throw MacClippyBackupError.corruptedArchive }
            let combined = try readExact(combinedLength, from: handle)
            let aad = chunkAAD(archiveID: header.archiveID, index: chunkIndex, isFinal: isFinalByte)
            let plaintext: Data
            do {
                let box = try AES.GCM.SealedBox(combined: combined)
                plaintext = try AES.GCM.open(box, using: header.archiveKey, authenticating: aad)
            } catch {
                throw MacClippyBackupError.corruptedArchive
            }
            try decoder.consume(plaintext)
            chunkIndex += 1
            sawFinal = isFinalByte == 1
        }
        guard sawFinal else { throw MacClippyBackupError.corruptedArchive }
    }

    static func chunkAAD(archiveID: Data, index: UInt64, isFinal: UInt8) -> Data {
        var data = Data()
        data.append(magic)
        data.append(archiveID)
        data.append(bigEndianBytes(index))
        data.append(isFinal)
        return data
    }

    static func headerAADBytes(archiveID: Data, iterations: UInt32, salt: Data) -> Data {
        var data = Data()
        data.append(magic)
        data.append(archiveID)
        data.append(bigEndianBytes(iterations))
        data.append(salt)
        return data
    }

    static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw MacClippyBackupError.corruptedArchive }
        return Data(bytes)
    }

    static func deriveArchiveKey(
        passphrase: String,
        salt: Data,
        iterations: UInt32
    ) throws -> SymmetricKey {
        guard !passphrase.isEmpty else { throw MacClippyBackupError.passphraseRequired }
        let passData = Data(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = passData.withUnsafeBytes { passRaw in
            salt.withUnsafeBytes { saltRaw -> Int32 in
                guard let passPtr = passRaw.bindMemory(to: CChar.self).baseAddress,
                      let saltPtr = saltRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return Int32(kCCParamError)
                }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passPtr,
                    passData.count,
                    saltPtr,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    iterations,
                    &derived,
                    derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw MacClippyBackupError.corruptedArchive }
        return SymmetricKey(data: Data(derived))
    }

    static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private static func readUpTo(_ count: Int, from handle: FileHandle) throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            guard let chunk = try handle.read(upToCount: count - buffer.count), !chunk.isEmpty else {
                break
            }
            buffer.append(chunk)
        }
        return buffer
    }

    private static func readExact(_ count: Int, from handle: FileHandle) throws -> Data {
        let data = try readUpTo(count, from: handle)
        guard data.count == count else { throw MacClippyBackupError.corruptedArchive }
        return data
    }

    private static func readUInt16(from handle: FileHandle) throws -> UInt16 {
        let data = try readExact(2, from: handle)
        return UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
    }

    private static func readUInt32(from handle: FileHandle) throws -> UInt32 {
        readUInt32(from: try readExact(4, from: handle))
    }

    private static func readUInt32(from data: Data) -> UInt32 {
        var value: UInt32 = 0
        for byte in data {
            value = (value << 8) | UInt32(byte)
        }
        return value
    }
}
