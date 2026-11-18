import Foundation
import MacClippyCore

enum MacClippyCloudBackupSchedule: String, CaseIterable, Identifiable, Sendable {
    case off
    case daily
    case weekly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }

    var intervalSeconds: TimeInterval? {
        switch self {
        case .off: nil
        case .daily: 86_400
        case .weekly: 7 * 86_400
        }
    }
}

struct MacClippyCloudLocalBackupItem: Identifiable, Sendable, Equatable {
    let url: URL
    let name: String
    let modifiedAt: Date
    let byteCount: Int64
    let isCloudPlaceholder: Bool

    var id: String { url.path }
}

@MainActor
final class MacClippyCloudBackupManager: ObservableObject {
    static let shared = MacClippyCloudBackupManager()
    static let defaultKeepLatest = 5

    private static let prefix = "com.macallyouneed.macclippy.cloudBackup."
    static let iCloudEnabledKey = prefix + "iCloudEnabled"
    static let iCloudBookmarkKey = prefix + "iCloudBookmark"
    static let scheduleKey = prefix + "schedule"
    static let lastBackupKey = prefix + "lastBackupAt"
    static let googleClientIDKey = prefix + "googleClientID"

    @Published var iCloudEnabled: Bool
    @Published var schedule: MacClippyCloudBackupSchedule
    @Published var lastBackupDate: Date?
    @Published var googleClientID: String
    @Published var isGoogleConnected: Bool
    @Published var hasSavedPassphrase: Bool

    let defaults: UserDefaults
    let keychain: MacClippyCloudBackupKeychain
    let driveClient: MacClippyGoogleDriveClient
    private let fileManager: FileManager
    private let isAutomatedTestRun: Bool

    init(
        defaults: UserDefaults = .standard,
        keychain: MacClippyCloudBackupKeychain = MacClippyCloudBackupKeychain(),
        driveClient: MacClippyGoogleDriveClient? = nil,
        fileManager: FileManager = .default,
        isAutomatedTestRun: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.driveClient = driveClient ?? MacClippyGoogleDriveClient(keychain: keychain)
        self.fileManager = fileManager
        self.isAutomatedTestRun = isAutomatedTestRun
        self.iCloudEnabled = defaults.bool(forKey: Self.iCloudEnabledKey)
        let rawSchedule = defaults.string(forKey: Self.scheduleKey) ?? MacClippyCloudBackupSchedule.off.rawValue
        self.schedule = MacClippyCloudBackupSchedule(rawValue: rawSchedule) ?? .off
        if let timestamp = defaults.object(forKey: Self.lastBackupKey) as? Double {
            self.lastBackupDate = Date(timeIntervalSince1970: timestamp)
        } else {
            self.lastBackupDate = nil
        }
        self.googleClientID = defaults.string(forKey: Self.googleClientIDKey) ?? ""
        self.isGoogleConnected = (driveClient ?? self.driveClient).isConnected
        self.hasSavedPassphrase = keychain.loadPassphrase() != nil
    }

    static var defaultICloudBackupsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/MacClippy Backups", isDirectory: true)
    }

    var resolvedICloudFolderURL: URL {
        if let bookmarkData = defaults.data(forKey: Self.iCloudBookmarkKey) {
            var isStale = false
            if let bookmarked = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return bookmarked
            }
        }
        return Self.defaultICloudBackupsDirectory
    }

    func setICloudEnabled(_ enabled: Bool) {
        iCloudEnabled = enabled
        defaults.set(enabled, forKey: Self.iCloudEnabledKey)
    }

    func setSchedule(_ newValue: MacClippyCloudBackupSchedule) {
        schedule = newValue
        defaults.set(newValue.rawValue, forKey: Self.scheduleKey)
    }

    func setGoogleClientID(_ clientID: String) {
        googleClientID = clientID
        defaults.set(clientID, forKey: Self.googleClientIDKey)
    }

    func saveCustomICloudFolder(_ url: URL) throws {
        // Non-sandboxed build: use minimal bookmark (never .withSecurityScope).
        let data = try url.bookmarkData(options: [.minimalBookmark])
        defaults.set(data, forKey: Self.iCloudBookmarkKey)
    }

    func clearCustomICloudFolder() {
        defaults.removeObject(forKey: Self.iCloudBookmarkKey)
    }

    func savePassphrase(_ passphrase: String) throws {
        try keychain.savePassphrase(passphrase)
        hasSavedPassphrase = !passphrase.isEmpty
    }

    func refreshConnectionState() {
        isGoogleConnected = driveClient.isConnected
        hasSavedPassphrase = keychain.loadPassphrase() != nil
    }

    func markBackupSucceeded(at date: Date = Date()) {
        lastBackupDate = date
        defaults.set(date.timeIntervalSince1970, forKey: Self.lastBackupKey)
    }

    nonisolated static func timestampedArchiveFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "MacClippy-Backup-\(formatter.string(from: now)).\(MacClippyBackupSettingsPolicy.archivePathExtension)"
    }

    func publishArchiveToFolder(
        sourceArchiveURL: URL,
        fileName: String,
        folderURL: URL,
        keepLatest: Int = MacClippyCloudBackupManager.defaultKeepLatest
    ) throws -> URL {
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let destinationURL = folderURL.appendingPathComponent(fileName)
        let stagingURL = folderURL.appendingPathComponent(".staging-\(UUID().uuidString)-\(fileName)")
        try fileManager.copyItem(at: sourceArchiveURL, to: stagingURL)
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
            } else {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
        rotateArchives(in: folderURL, keepLatest: keepLatest)
        return destinationURL
    }

    func listLocalArchives(in folderURL: URL) -> [MacClippyCloudLocalBackupItem] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: []
        ) else {
            return []
        }
        var items: [String: MacClippyCloudLocalBackupItem] = [:]
        for url in urls {
            if url.pathExtension.lowercased() == MacClippyBackupSettingsPolicy.archivePathExtension {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let item = MacClippyCloudLocalBackupItem(
                    url: url,
                    name: url.lastPathComponent,
                    modifiedAt: values?.contentModificationDate ?? .distantPast,
                    byteCount: Int64(values?.fileSize ?? 0),
                    isCloudPlaceholder: false
                )
                items[item.name] = item
            } else if let targetName = Self.realArchiveName(forICloudPlaceholder: url.lastPathComponent) {
                let targetURL = folderURL.appendingPathComponent(targetName)
                guard items[targetName] == nil else { continue }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                items[targetName] = MacClippyCloudLocalBackupItem(
                    url: targetURL,
                    name: targetName,
                    modifiedAt: values?.contentModificationDate ?? .distantPast,
                    byteCount: Int64(values?.fileSize ?? 0),
                    isCloudPlaceholder: true
                )
            }
        }
        return items.values.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    static func realArchiveName(forICloudPlaceholder filename: String) -> String? {
        let suffix = ".\(MacClippyBackupSettingsPolicy.archivePathExtension).icloud"
        guard filename.hasPrefix("."), filename.hasSuffix(suffix) else { return nil }
        return String(filename.dropFirst().dropLast(".icloud".count))
    }

    func rotateArchives(in folderURL: URL, keepLatest: Int = MacClippyCloudBackupManager.defaultKeepLatest) {
        let managed = listLocalArchives(in: folderURL).filter {
            $0.name.hasPrefix("MacClippy-Backup-")
                && $0.name.hasSuffix(".\(MacClippyBackupSettingsPolicy.archivePathExtension)")
        }
        guard managed.count > keepLatest else { return }
        for obsolete in managed.dropFirst(keepLatest) {
            try? fileManager.removeItem(at: obsolete.url)
        }
    }

    nonisolated func hydrateCloudFileIfNeeded(
        at archiveURL: URL,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> URL {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: archiveURL.path) {
            let values = try? archiveURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if values?.ubiquitousItemDownloadingStatus != .notDownloaded {
                return archiveURL
            }
        }
        let placeholderURL = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(".\(archiveURL.lastPathComponent).icloud")
        let triggerURL = fileManager.fileExists(atPath: placeholderURL.path) ? placeholderURL : archiveURL
        try fileManager.startDownloadingUbiquitousItem(at: triggerURL)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if fileManager.fileExists(atPath: archiveURL.path) {
                let values = try? archiveURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                if values?.ubiquitousItemDownloadingStatus == nil
                    || values?.ubiquitousItemDownloadingStatus == .current
                    || values?.ubiquitousItemDownloadingStatus == .downloaded {
                    return archiveURL
                }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw MacClippyBackupError.corruptedArchive
    }

    func isScheduledBackupDue(now: Date = Date()) -> Bool {
#if MACCLIPPY_E2E
        return false
#else
        guard !isAutomatedTestRun,
              let interval = schedule.intervalSeconds,
              hasSavedPassphrase,
              iCloudEnabled || isGoogleConnected else {
            return false
        }
        guard let lastBackupDate else { return true }
        return now.timeIntervalSince(lastBackupDate) >= interval
#endif
    }
}

extension MacClippyCloudBackupManager {
    func runScheduledBackupIfDue(delegate: AppDelegate) {
#if !MACCLIPPY_E2E
        guard isScheduledBackupDue(), let passphrase = keychain.loadPassphrase() else { return }
        let fileName = Self.timestampedArchiveFileName()
        let tempArchiveURL = fileManager.temporaryDirectory.appendingPathComponent(fileName)
        delegate.createArchiveBackup(at: tempArchiveURL, passphrase: passphrase, overwrite: true) { result in
            guard case .success = result else {
                try? self.fileManager.removeItem(at: tempArchiveURL)
                return
            }
            Task {
                defer { try? self.fileManager.removeItem(at: tempArchiveURL) }
                var anySucceeded = false
                if self.iCloudEnabled {
                    if (try? self.publishArchiveToFolder(
                        sourceArchiveURL: tempArchiveURL,
                        fileName: fileName,
                        folderURL: self.resolvedICloudFolderURL
                    )) != nil {
                        anySucceeded = true
                    }
                }
                if self.isGoogleConnected {
                    if (try? await self.driveClient.uploadBackup(
                        fileURL: tempArchiveURL,
                        fileName: fileName
                    )) != nil {
                        try? await self.driveClient.pruneOldBackups(keepLatest: Self.defaultKeepLatest)
                        anySucceeded = true
                    }
                }
                if anySucceeded {
                    self.markBackupSucceeded()
                }
            }
        }
#endif
    }
}
