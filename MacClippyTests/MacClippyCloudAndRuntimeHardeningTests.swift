import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippyCloudAndRuntimeHardeningTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyCloudTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubURLProtocol.setHandler(nil)
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testCompressedImagePreservesAlphaChannelAndCompressesOpaqueAsJPEG() throws {
        let transparentPNG = try makeSamplePNGData(alpha: true, width: 600, height: 600)
        let compressedAlpha = try XCTUnwrap(
            MacClippyThumbnailDownsampler.compressedImage(from: transparentPNG, maxPixelSize: 300)
        )
        XCTAssertTrue(
            compressedAlpha.uti == UTType.heic.identifier || compressedAlpha.uti == UTType.png.identifier
        )
        let decodedAlpha = try XCTUnwrap(MacClippyThumbnailDownsampler.image(fromPNG: compressedAlpha.data))
        XCTAssertNotEqual(decodedAlpha.alphaInfo, .none)

        let opaquePNG = try makeSamplePNGData(alpha: false, width: 600, height: 600)
        let compressedOpaque = try XCTUnwrap(
            MacClippyThumbnailDownsampler.compressedImage(from: opaquePNG, maxPixelSize: 300)
        )
        XCTAssertEqual(compressedOpaque.uti, UTType.jpeg.identifier)
    }

    @MainActor
    func testDockModelEndSessionTrimsHistoryTailAndFiltersSnippetFolders() throws {
        let runtime = try MacClippyRuntime(
            paths: MacClippyPaths(rootURL: tempRoot.appendingPathComponent("store", isDirectory: true)),
            keychain: MacClippyInMemoryKeychain(),
            enableSnippetExpansion: false
        )
        defer { runtime.closeForTesting() }

        let model = MacClippyDockModel(runtime: runtime)
        let entries = try (0..<25).map { index in
            try runtime.appendTestRecord(.text("item-\(index)"))
        }.compactMap { try runtime.entry(for: $0) }
        model.historyItems = entries
        model.historyHasMore = false

        model.endSession(resetCaches: true)
        XCTAssertEqual(model.historyItems.count, 16)
        XCTAssertTrue(model.historyHasMore)

        let workSnippet = try runtime.createSnippet(name: "Work", trigger: ":w", body: "Work body", folder: "Work")
        let homeSnippet = try runtime.createSnippet(name: "Home", trigger: ":h", body: "Home body", folder: "Personal")
        model.snippets = [workSnippet, homeSnippet]
        model.selectedTab = .snippets
        model.selectSnippetFolder("Work")
        XCTAssertEqual(model.availableSnippetFolders, ["Personal", "Work"])
        XCTAssertEqual(model.visibleSnippets.map(\.name), ["Work"])
    }

    @MainActor
    func testCloudBackupManagerPublishesRotatesToFiveAndDetectsICloudPlaceholders() throws {
        let suite = "MacClippyCloudManager-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let keychain = MacClippyCloudBackupKeychain(backend: MacClippyInMemoryKeychain())
        let client = MacClippyGoogleDriveClient(keychain: keychain)
        let manager = MacClippyCloudBackupManager(
            defaults: defaults,
            keychain: keychain,
            driveClient: client,
            isAutomatedTestRun: true
        )

        let iCloudDir = tempRoot.appendingPathComponent("iCloud", isDirectory: true)
        for index in 1...7 {
            let source = tempRoot.appendingPathComponent("src-\(index).macclippybackup")
            try Data("archive-\(index)".utf8).write(to: source)
            let name = String(format: "MacClippy-Backup-2026-11-0%d-000000.macclippybackup", index)
            _ = try manager.publishArchiveToFolder(
                sourceArchiveURL: source,
                fileName: name,
                folderURL: iCloudDir,
                keepLatest: 5
            )
            Thread.sleep(forTimeInterval: 0.01)
        }
        let listed = manager.listLocalArchives(in: iCloudDir)
        XCTAssertEqual(listed.count, 5)
        XCTAssertEqual(listed.first?.name, "MacClippy-Backup-2026-11-07-000000.macclippybackup")

        let placeholder = iCloudDir.appendingPathComponent(".MacClippy-Backup-2026-11-08-000000.macclippybackup.icloud")
        try Data("stub".utf8).write(to: placeholder)
        let withPlaceholder = manager.listLocalArchives(in: iCloudDir)
        XCTAssertTrue(withPlaceholder.contains {
            $0.name == "MacClippy-Backup-2026-11-08-000000.macclippybackup" && $0.isCloudPlaceholder
        })
    }

    func testGoogleDriveClientMakesZeroNetworkCallsWhenDisconnected() async throws {
        let keychain = MacClippyCloudBackupKeychain(backend: MacClippyInMemoryKeychain())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = MacClippyGoogleDriveClient(keychain: keychain, session: session, openBrowser: { _ in false })

        var hitCount = 0
        StubURLProtocol.setHandler { _ in
            hitCount += 1
            throw URLError(.cannotConnectToHost)
        }
        do {
            _ = try await client.listBackups()
            XCTFail("Expected disconnected client to fail without HTTP requests")
        } catch let error as MacClippyGoogleDriveError {
            XCTAssertEqual(error, .notConnected)
        }
        XCTAssertEqual(hitCount, 0)
    }

    func testGoogleDriveClientSendsSecretAndResumableUploadRange() async throws {
        let keychain = MacClippyCloudBackupKeychain(backend: MacClippyInMemoryKeychain())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = MacClippyGoogleDriveClient(keychain: keychain, session: session, openBrowser: { _ in false })

        StubURLProtocol.setHandler { request in
            let bodyText = Self.bodyText(from: request)
            XCTAssertTrue(bodyText.contains("client_secret=my-secret"))
            XCTAssertTrue(bodyText.contains("grant_type=authorization_code"))
            let json = Data(#"{"access_token":"tok","refresh_token":"ref","expires_in":3600}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, json)
        }
        let tokens = try await client.exchangeAuthorizationCode(
            code: "abc",
            clientID: "cid",
            clientSecret: "my-secret",
            redirectURI: "http://127.0.0.1:9999/callback",
            codeVerifier: "verifier"
        )
        try keychain.saveGoogleTokens(tokens)

        let archiveURL = tempRoot.appendingPathComponent("upload.macclippybackup")
        try Data(repeating: 0x5A, count: 1_024).write(to: archiveURL)

        var seenRanges: [String] = []
        StubURLProtocol.setHandler { request in
            if request.url?.absoluteString.contains("uploadType=resumable") == true {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Location": "https://upload.example.invalid/session-1"]
                )!
                return (response, Data())
            }
            seenRanges.append(request.value(forHTTPHeaderField: "Content-Range") ?? "")
            let json = Data(#"{"id":"f1","name":"b.macclippybackup","size":"1024"}"#.utf8)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, json)
        }
        let uploaded = try await client.uploadBackup(fileURL: archiveURL, fileName: "b.macclippybackup")
        XCTAssertEqual(uploaded.id, "f1")
        XCTAssertEqual(seenRanges, ["bytes 0-1023/1024"])
    }

    private static func bodyText(from request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(bytes: body, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    private func makeSamplePNGData(alpha: Bool, width: Int, height: Int) throws -> Data {
        let info = alpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info
        ))
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: alpha ? 0.5 : 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        return try XCTUnwrap(MacClippyThumbnailDownsampler.pngData(from: image))
    }
}

private final class StubURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    func set(_ handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func get() -> ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }
}

private final class StubURLProtocol: URLProtocol {
    private static let state = StubURLProtocolState()

    static func setHandler(_ handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?) {
        state.set(handler)
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.state.get() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
