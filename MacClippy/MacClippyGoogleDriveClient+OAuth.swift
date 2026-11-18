import CryptoKit
import Darwin
import Foundation
import Security

extension MacClippyGoogleDriveClient {
    struct PKCEChallenge {
        let verifier: String
        let challenge: String
        let state: String
    }

    static func ensureNetworkingAllowed() throws {
#if MACCLIPPY_E2E
        throw MacClippyGoogleDriveError.disabledInE2E
#endif
    }

    static func validateHTTPStatus(_ response: URLResponse, allowed: ClosedRange<Int>) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MacClippyGoogleDriveError.invalidResponse
        }
        guard allowed.contains(http.statusCode) else {
            throw MacClippyGoogleDriveError.httpFailure(http.statusCode)
        }
    }

    func connectInteractive(
        clientID: String,
        clientSecret: String
    ) async throws -> MacClippyGoogleOAuthTokens {
        try Self.ensureNetworkingAllowed()
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else { throw MacClippyGoogleDriveError.missingClientID }

        let listener = try LoopbackOAuthListener()
        let redirectURI = "http://127.0.0.1:\(listener.port)/callback"
        let pkce = Self.makePKCEChallenge()
        let authURL = try Self.authorizationURL(
            clientID: trimmedClientID,
            redirectURI: redirectURI,
            pkce: pkce
        )
        guard openBrowser(authURL) else {
            listener.cancel()
            throw MacClippyGoogleDriveError.authorizationCancelled
        }
        let code = try await listener.waitForAuthorizationCode(expectedState: pkce.state)
        let tokens = try await exchangeAuthorizationCode(
            code: code,
            clientID: trimmedClientID,
            clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            redirectURI: redirectURI,
            codeVerifier: pkce.verifier
        )
        try keychain.saveGoogleTokens(tokens)
        return tokens
    }

    func exchangeAuthorizationCode(
        code: String,
        clientID: String,
        clientSecret: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> MacClippyGoogleOAuthTokens {
        var params = [
            "client_id": clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code"
        ]
        if !clientSecret.isEmpty {
            params["client_secret"] = clientSecret
        }
        let payload = try await postTokenRequest(parameters: params)
        return MacClippyGoogleOAuthTokens(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(max(60, payload.expiresIn - 30))),
            clientID: clientID,
            clientSecret: clientSecret,
            accountEmail: nil
        )
    }

    func validAccessToken() async throws -> String {
        try Self.ensureNetworkingAllowed()
        guard var tokens = keychain.loadGoogleTokens() else {
            throw MacClippyGoogleDriveError.notConnected
        }
        if tokens.expiresAt > Date().addingTimeInterval(60) {
            return tokens.accessToken
        }
        guard !tokens.refreshToken.isEmpty else {
            throw MacClippyGoogleDriveError.notConnected
        }
        var params = [
            "client_id": tokens.clientID,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token"
        ]
        if !tokens.clientSecret.isEmpty {
            params["client_secret"] = tokens.clientSecret
        }
        let refreshed = try await postTokenRequest(parameters: params)
        tokens.accessToken = refreshed.accessToken
        tokens.expiresAt = Date().addingTimeInterval(TimeInterval(max(60, refreshed.expiresIn - 30)))
        if let newRefresh = refreshed.refreshToken, !newRefresh.isEmpty {
            tokens.refreshToken = newRefresh
        }
        try keychain.saveGoogleTokens(tokens)
        return tokens.accessToken
    }

    static func authorizationURL(
        clientID: String,
        redirectURI: String,
        pkce: PKCEChallenge
    ) throws -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: driveAppDataScope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        guard let url = components?.url else { throw MacClippyGoogleDriveError.invalidResponse }
        return url
    }

    static func makePKCEChallenge() -> PKCEChallenge {
        let verifierData = randomBytes(count: 32)
        let verifier = base64URLEncode(verifierData)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncode(Data(digest))
        let state = base64URLEncode(randomBytes(count: 16))
        return PKCEChallenge(verifier: verifier, challenge: challenge, state: state)
    }

    private func postTokenRequest(parameters: [String: String]) async throws -> GoogleTokenResponse {
        try Self.ensureNetworkingAllowed()
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw MacClippyGoogleDriveError.invalidResponse
        }
        var components = URLComponents()
        components.queryItems = parameters.sorted { $0.key < $1.key }.map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request)
        try Self.validateHTTPStatus(response, allowed: 200...299)
        return try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
    }

    private static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct GoogleTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private final class LoopbackOAuthListener: @unchecked Sendable {
    private let listenFD: Int32
    let port: UInt16

    init() throws {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw MacClippyGoogleDriveError.loopbackStartFailed }
        var reuse: Int32 = 1
        Darwin.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(sock, 1) == 0 else {
            Darwin.close(sock)
            throw MacClippyGoogleDriveError.loopbackStartFailed
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.getsockname(sock, sockPtr, &addrLen)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(sock)
            throw MacClippyGoogleDriveError.loopbackStartFailed
        }
        listenFD = sock
        port = UInt16(bigEndian: boundAddr.sin_port)
    }

    func cancel() {
        Darwin.close(listenFD)
    }

    func waitForAuthorizationCode(expectedState: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [listenFD] in
                defer { Darwin.close(listenFD) }
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.accept(listenFD, sockPtr, &clientLen)
                    }
                }
                guard clientFD >= 0 else {
                    continuation.resume(throwing: MacClippyGoogleDriveError.authorizationCancelled)
                    return
                }
                defer { Darwin.close(clientFD) }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                let bytesRead = Darwin.read(clientFD, &buffer, buffer.count)
                let requestText = bytesRead > 0
                    ? (String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? "")
                    : ""
                let html = """
                HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\
                <html><body><h3>Mac Clippy signed in.</h3><p>You can close this tab.</p></body></html>
                """
                let reply = Array(html.utf8)
                _ = Darwin.write(clientFD, reply, reply.count)
                continuation.resume(with: Self.extractCode(from: requestText, expectedState: expectedState))
            }
        }
    }

    private static func extractCode(from requestText: String, expectedState: String) -> Result<String, Error> {
        guard let firstLine = requestText.split(separator: "\r\n", maxSplits: 1).first else {
            return .failure(MacClippyGoogleDriveError.missingAuthorizationCode)
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])") else {
            return .failure(MacClippyGoogleDriveError.missingAuthorizationCode)
        }
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        if items["error"] != nil {
            return .failure(MacClippyGoogleDriveError.authorizationCancelled)
        }
        guard items["state"] == expectedState else {
            return .failure(MacClippyGoogleDriveError.invalidOAuthState)
        }
        guard let code = items["code"], !code.isEmpty else {
            return .failure(MacClippyGoogleDriveError.missingAuthorizationCode)
        }
        return .success(code)
    }
}
