#if MACCLIPPY_E2E
import AppKit
import Foundation
import Darwin

import MacClippyCore
import MacClippyPlatform

enum MacClippyE2EIsolationError: Error, CustomStringConvertible {
    case missingRuntimeDependencies
    case invalidConfiguration
    case invalidRoot
    case invalidMarker
    case liveRootOverlap
    case rootAlreadyInUse
    case unsafeRootContents
    case keyUnavailable
    case keyPermissions
    case controlSocketPathTooLong

    var description: String {
        switch self {
        case .missingRuntimeDependencies: "e2e-runtime-dependencies-required"
        case .invalidConfiguration: "e2e-configuration-invalid"
        case .invalidRoot: "e2e-root-invalid"
        case .invalidMarker: "e2e-root-marker-invalid"
        case .liveRootOverlap: "e2e-root-overlaps-live-data"
        case .rootAlreadyInUse: "e2e-root-already-in-use"
        case .unsafeRootContents: "e2e-root-contains-unsafe-paths"
        case .keyUnavailable: "e2e-device-key-unavailable"
        case .keyPermissions: "e2e-device-key-permissions-invalid"
        case .controlSocketPathTooLong: "e2e-control-socket-path-too-long"
        }
    }
}

final class MacClippyE2EIsolation: @unchecked Sendable {
    static let bundleIdentifier = "com.macallyouneed.macclippy.e2e"
    static let markerName = ".macclippy-e2e-root.json"
    static let keyName = ".macclippy-e2e-device-key-v1"
    static let lockName = ".macclippy-e2e-instance.lock"
    static let sourceAppBundleIdentifier = "com.macallyouneed.macclippy.e2e.synthetic"

    struct Marker: Decodable {
        let schemaVersion: Int
        let runID: String
        let ownerUID: Int
        let createdBy: String
    }

    private struct Configuration {
        let rootURL: URL
        let runID: String
        let retentionMaxItems: Int
    }

    private struct Resources {
        let paths: MacClippyPaths
        let defaults: UserDefaults
        let pasteboard: NSPasteboard
        let keychain: MacClippyKeychainBackend
    }

    let runID: String
    let rootURL: URL
    let retentionMaxItems: Int
    let paths: MacClippyPaths
    let defaults: UserDefaults
    let pasteboard: NSPasteboard
    let pasteboardAccessCoordinator: MacClippyPasteboardAccessCoordinator
    let pasteboardWriteSentinel = MacClippyPasteboardWriteSentinel()
    let keychain: MacClippyKeychainBackend
    private let instanceLockDescriptor: Int32
    private let diagnosticsLock = NSLock()
    private let defaultsDisposalLock = NSLock()
    private var didDisposePerRunDefaultsDomain = false

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws {
        let configuration = try Self.resolveConfiguration(
            environment: environment,
            bundleIdentifier: bundleIdentifier
        )
        let lockDescriptor = try Self.openInstanceLock(rootURL: configuration.rootURL)
        do {
            let resources = try Self.makeResources(
                rootURL: configuration.rootURL,
                runID: configuration.runID
            )
            runID = configuration.runID
            rootURL = configuration.rootURL
            retentionMaxItems = configuration.retentionMaxItems
            paths = resources.paths
            defaults = resources.defaults
            pasteboard = resources.pasteboard
            pasteboardAccessCoordinator = .shared(for: resources.pasteboard)
            keychain = resources.keychain
            instanceLockDescriptor = lockDescriptor
        } catch {
            close(lockDescriptor)
            throw error
        }
    }

    private static func resolveConfiguration(
        environment: [String: String],
        bundleIdentifier: String?
    ) throws -> Configuration {
        guard bundleIdentifier == Self.bundleIdentifier,
              let configuredRoot = environment["MACCLIPPY_E2E_ROOT"],
              configuredRoot.hasPrefix("/"),
              let configuredRunID = environment["MACCLIPPY_E2E_RUN_ID"],
              UUID(uuidString: configuredRunID) != nil else {
            throw MacClippyE2EIsolationError.invalidConfiguration
        }
        let retentionMaxItems: Int
        do {
            retentionMaxItems = try MacClippyE2ERetentionConfiguration.maximumItems(
                environment: environment
            )
        } catch {
            throw MacClippyE2EIsolationError.invalidConfiguration
        }

        let inputURL = URL(fileURLWithPath: configuredRoot, isDirectory: true)
        guard inputURL.isFileURL, inputURL.path.hasPrefix("/") else {
            throw MacClippyE2EIsolationError.invalidRoot
        }
        let resolvedRoot = inputURL.standardizedFileURL.resolvingSymlinksInPath()
        try Self.validateTemporaryRoot(resolvedRoot)
        try Self.validateNoLiveRootOverlap(resolvedRoot)
        try Self.validateDirectory(resolvedRoot)

        let markerURL = resolvedRoot.appendingPathComponent(Self.markerName)
        try Self.validateRegularFile(markerURL, requiredMode: 0o600)
        let markerData = try Data(contentsOf: markerURL, options: [.mappedIfSafe])
        guard let marker = try? JSONDecoder().decode(Marker.self, from: markerData),
              marker.schemaVersion == 1,
              marker.runID.caseInsensitiveCompare(configuredRunID) == .orderedSame,
              marker.ownerUID == Int(getuid()),
              marker.createdBy == "macclippy-phase5-e2e-runner" else {
            throw MacClippyE2EIsolationError.invalidMarker
        }

        return Configuration(
            rootURL: resolvedRoot,
            runID: configuredRunID.lowercased(),
            retentionMaxItems: retentionMaxItems
        )
    }

    private static func openInstanceLock(rootURL: URL) throws -> Int32 {
        let lockURL = rootURL.appendingPathComponent(Self.lockName)
        let lockDescriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard lockDescriptor >= 0 else { throw MacClippyE2EIsolationError.rootAlreadyInUse }
        guard fchmod(lockDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0,
              flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(lockDescriptor)
            throw MacClippyE2EIsolationError.rootAlreadyInUse
        }
        return lockDescriptor
    }

    private static func makeResources(rootURL: URL, runID: String) throws -> Resources {
        try validateNoSymlinksBelow(rootURL)
        let paths = try MacClippyPaths(rootURL: rootURL)
        try validateDerivedPaths(paths, inside: rootURL)
        let suiteName = "com.macallyouneed.macclippy.e2e.run.\(runID)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw MacClippyE2EIsolationError.invalidConfiguration
        }
        defaults.set(true, forKey: MacClippyRetentionPreferences.captureAllKey)
        defaults.set(false, forKey: MacClippyRetentionPreferences.privacyPauseKey)
        defaults.removeObject(forKey: MacClippyRetentionPreferences.pauseUntilKey)
        let pasteboardName = NSPasteboard.Name("com.macallyouneed.macclippy.e2e.\(runID)")
        return Resources(
            paths: paths,
            defaults: defaults,
            pasteboard: NSPasteboard(name: pasteboardName),
            keychain: MacClippyE2EFileKeychain(url: rootURL.appendingPathComponent(Self.keyName))
        )
    }

    deinit {
        disposePerRunDefaultsDomain()
        close(instanceLockDescriptor)
    }

    private static func validateTemporaryRoot(_ rootURL: URL) throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard rootURL.deletingLastPathComponent().path == temporaryRoot.path,
              rootURL.lastPathComponent.hasPrefix("mce5-"),
              isEqualOrDescendant(rootURL.path, of: temporaryRoot.path) else {
            throw MacClippyE2EIsolationError.invalidRoot
        }
    }

    private static func validateNoLiveRootOverlap(_ rootURL: URL) throws {
        let supportRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let liveRoot = supportRoot.appendingPathComponent("MacClippy", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard !isEqualOrDescendant(rootURL.path, of: liveRoot.path),
              !isEqualOrDescendant(liveRoot.path, of: rootURL.path) else {
            throw MacClippyE2EIsolationError.liveRootOverlap
        }
    }

    private static func validateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else {
            throw MacClippyE2EIsolationError.invalidRoot
        }
    }

    private static func validateRegularFile(_ url: URL, requiredMode: Int) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0,
              (info.st_mode & mode_t(requiredMode)) == mode_t(requiredMode) else {
            throw MacClippyE2EIsolationError.invalidMarker
        }
    }

    private static func validateDerivedPaths(_ paths: MacClippyPaths, inside rootURL: URL) throws {
        let children = [
            paths.databasesURL,
            paths.blobsURL,
            paths.thumbnailsURL,
            paths.clipboardDatabaseURL,
            paths.searchDatabaseURL,
            paths.pinboardDatabaseURL,
            paths.snippetDatabaseURL,
            paths.diagnosticsJournalURL
        ]
        guard children.allSatisfy({
            isEqualOrDescendant(
                $0.standardizedFileURL.resolvingSymlinksInPath().path,
                of: rootURL.path
            )
        }) else {
            throw MacClippyE2EIsolationError.unsafeRootContents
        }
    }

    private static func isEqualOrDescendant(_ path: String, of parent: String) -> Bool {
        path == parent || path.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }
}

extension MacClippyE2EIsolation {
    func disposePerRunDefaultsDomain() {
        defaultsDisposalLock.lock()
        defer { defaultsDisposalLock.unlock() }
        guard !didDisposePerRunDefaultsDomain else { return }
        let domainName = "com.macallyouneed.macclippy.e2e.run.\(runID)"
        guard let uuid = UUID(uuidString: runID),
              uuid.uuidString.lowercased() == runID.lowercased(),
              domainName == "com.macallyouneed.macclippy.e2e.run.\(uuid.uuidString.lowercased())" else {
            return
        }
        didDisposePerRunDefaultsDomain = true
        defaults.removePersistentDomain(forName: domainName)
        let record: [String: Any] = [
            "schemaVersion": 1,
            "runID": runID,
            "persistentDomain": domainName,
            "removed": defaults.persistentDomain(forName: domainName) == nil,
            "atUTC": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        let path = rootURL.appendingPathComponent("e2e-defaults-disposal.json")
        let descriptor = open(
            path.path,
            O_CREAT | O_TRUNC | O_WRONLY | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else { return }
        var payload = data
        payload.append(0x0A)
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            guard written > 0 else { return }
            offset += written
        }
    }

    func recordDiagnostic(category: String, error: Error) {
        let path = rootURL.appendingPathComponent("e2e-diagnostics.jsonl")
        let detail = String(String(describing: error).prefix(768))
        let record: [String: String] = [
            "atUTC": ISO8601DateFormatter().string(from: Date()),
            "category": String(category.prefix(64)),
            "detail": detail
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              data.count <= 4_096 else { return }

        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        let descriptor = open(
            path.path,
            O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0,
              info.st_size >= 0,
              info.st_size + off_t(data.count + 1) <= 65_536 else { return }

        var payload = data
        payload.append(0x0A)
        var offset = 0
        while offset < payload.count {
            let written = payload.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            guard written > 0 else { return }
            offset += written
        }
    }
}

#endif
