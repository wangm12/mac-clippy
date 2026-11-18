import AppKit
import CryptoKit
import Darwin
import Foundation

enum MacClippyGoogleDriveError: Error, LocalizedError, Equatable {
    case disabledInE2E
    case missingClientID
    case notConnected
    case authorizationCancelled
    case invalidOAuthState
    case loopbackStartFailed
    case missingAuthorizationCode
    case httpFailure(Int)
    case missingUploadLocation
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .disabledInE2E:
            return "Google Drive networking is disabled in E2E mode."
        case .missingClientID:
            return "Enter a Google OAuth Client ID before connecting."
        case .notConnected:
            return "Google Drive is not connected."
        case .authorizationCancelled:
            return "Google Drive sign-in was cancelled."
        case .invalidOAuthState:
            return "Google sign-in state mismatch."
        case .loopbackStartFailed:
            return "Could not open local loopback port for Google OAuth."
        case .missingAuthorizationCode:
            return "Google sign-in did not return an authorization code."
        case let .httpFailure(code):
            return "Google Drive returned HTTP \(code)."
        case .missingUploadLocation:
            return "Google Drive did not return a resumable upload session URL."
        case .invalidResponse:
            return "Unexpected response from Google Drive."
        }
    }
}

struct MacClippyGoogleDriveBackupFile: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let name: String
    let sizeBytes: Int64
    let createdTime: Date
}

final class MacClippyGoogleDriveClient: @unchecked Sendable {
    static let driveAppDataScope = "https://www.googleapis.com/auth/drive.appdata"
    static let uploadChunkSize = 8 * 1024 * 1024

    let keychain: MacClippyCloudBackupKeychain
    let session: URLSession
    let openBrowser: @Sendable (URL) -> Bool

    init(
        keychain: MacClippyCloudBackupKeychain = MacClippyCloudBackupKeychain(),
        session: URLSession = .shared,
        openBrowser: @escaping @Sendable (URL) -> Bool = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        self.keychain = keychain
        self.session = session
        self.openBrowser = openBrowser
    }

    var isConnected: Bool {
        keychain.loadGoogleTokens() != nil
    }

    var connectedAccountSummary: String? {
        guard let tokens = keychain.loadGoogleTokens() else { return nil }
        return tokens.accountEmail ?? "Connected (appDataFolder)"
    }

    func disconnect() throws {
        try keychain.clearGoogleTokens()
    }

    func uploadBackup(
        fileURL: URL,
        fileName: String
    ) async throws -> MacClippyGoogleDriveBackupFile {
        try Self.ensureNetworkingAllowed()
        let accessToken = try await validAccessToken()
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        let totalBytes = Int64(values.fileSize ?? 0)
        let sessionURL = try await startResumableUpload(
            fileName: fileName,
            totalBytes: totalBytes,
            accessToken: accessToken
        )
        let uploaded = try await uploadFileChunks(
            fileURL: fileURL,
            totalBytes: totalBytes,
            sessionURL: sessionURL,
            accessToken: accessToken
        )
        return uploaded
    }

    func listBackups() async throws -> [MacClippyGoogleDriveBackupFile] {
        try Self.ensureNetworkingAllowed()
        let accessToken = try await validAccessToken()
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")
        components?.queryItems = [
            URLQueryItem(name: "spaces", value: "appDataFolder"),
            URLQueryItem(name: "q", value: "trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name,size,createdTime)"),
            URLQueryItem(name: "orderBy", value: "createdTime desc"),
            URLQueryItem(name: "pageSize", value: "50")
        ]
        guard let url = components?.url else { throw MacClippyGoogleDriveError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.validateHTTPStatus(response, allowed: 200...299)
        let decoded = try JSONDecoder().decode(DriveFileListResponse.self, from: data)
        return decoded.files.compactMap { Self.parseBackupFile($0) }
    }

    func downloadBackup(fileID: String, to destinationURL: URL) async throws {
        try Self.ensureNetworkingAllowed()
        let accessToken = try await validAccessToken()
        let encodedID = fileID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileID
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(encodedID)?alt=media") else {
            throw MacClippyGoogleDriveError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (tempURL, response) = try await session.download(for: request)
        try Self.validateHTTPStatus(response, allowed: 200...299)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }
    }

    func deleteBackup(fileID: String) async throws {
        try Self.ensureNetworkingAllowed()
        let accessToken = try await validAccessToken()
        let encodedID = fileID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileID
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(encodedID)") else {
            throw MacClippyGoogleDriveError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        try Self.validateHTTPStatus(response, allowed: 200...299)
    }

    func pruneOldBackups(keepLatest: Int) async throws {
        let backups = try await listBackups().filter {
            $0.name.hasPrefix("MacClippy-Backup-") && $0.name.hasSuffix(".macclippybackup")
        }
        guard backups.count > keepLatest else { return }
        for obsolete in backups.dropFirst(keepLatest) {
            try await deleteBackup(fileID: obsolete.id)
        }
    }
}

private extension MacClippyGoogleDriveClient {
    func startResumableUpload(
        fileName: String,
        totalBytes: Int64,
        accessToken: String
    ) async throws -> URL {
        guard let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable") else {
            throw MacClippyGoogleDriveError.invalidResponse
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "name": fileName,
            "parents": ["appDataFolder"]
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue("\(totalBytes)", forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = body

        let (_, response) = try await session.data(for: request)
        try Self.validateHTTPStatus(response, allowed: 200...299)
        guard let http = response as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: location) else {
            throw MacClippyGoogleDriveError.missingUploadLocation
        }
        return uploadURL
    }

    func uploadFileChunks(
        fileURL: URL,
        totalBytes: Int64,
        sessionURL: URL,
        accessToken: String
    ) async throws -> MacClippyGoogleDriveBackupFile {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var offset: Int64 = 0
        var finalResponseData: Data?
        while offset < totalBytes {
            let chunk = try readChunk(from: handle, maxBytes: Self.uploadChunkSize)
            guard !chunk.isEmpty else { throw MacClippyGoogleDriveError.invalidResponse }
            let endByte = offset + Int64(chunk.count) - 1
            var request = URLRequest(url: sessionURL)
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("bytes \(offset)-\(endByte)/\(totalBytes)", forHTTPHeaderField: "Content-Range")
            request.httpBody = chunk

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw MacClippyGoogleDriveError.invalidResponse }
            if http.statusCode == 308 {
                offset = endByte + 1
                continue
            }
            guard (200...299).contains(http.statusCode) else {
                throw MacClippyGoogleDriveError.httpFailure(http.statusCode)
            }
            finalResponseData = data
            offset = endByte + 1
        }
        guard let data = finalResponseData else { throw MacClippyGoogleDriveError.invalidResponse }
        let item = try JSONDecoder().decode(DriveFileMetadata.self, from: data)
        return MacClippyGoogleDriveBackupFile(
            id: item.id,
            name: item.name,
            sizeBytes: Int64(item.size ?? "") ?? totalBytes,
            createdTime: Self.parseISO8601Date(item.createdTime) ?? Date()
        )
    }

    func readChunk(from handle: FileHandle, maxBytes: Int) throws -> Data {
        var buffer = Data()
        while buffer.count < maxBytes {
            guard let slice = try handle.read(upToCount: maxBytes - buffer.count), !slice.isEmpty else {
                break
            }
            buffer.append(slice)
        }
        return buffer
    }

    static func parseBackupFile(_ item: DriveFileMetadata) -> MacClippyGoogleDriveBackupFile? {
        MacClippyGoogleDriveBackupFile(
            id: item.id,
            name: item.name,
            sizeBytes: Int64(item.size ?? "") ?? 0,
            createdTime: parseISO8601Date(item.createdTime) ?? Date()
        )
    }

    static func parseISO8601Date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFraction.date(from: raw) { return parsed }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }
}

struct DriveFileListResponse: Decodable {
    let files: [DriveFileMetadata]
}

struct DriveFileMetadata: Decodable {
    let id: String
    let name: String
    let size: String?
    let createdTime: String?
}
