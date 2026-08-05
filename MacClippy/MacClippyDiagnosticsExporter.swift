import ApplicationServices
import AppKit
import Foundation
import ServiceManagement

import MacClippyCore

struct MacClippyDiagnosticsExport: Codable, Sendable {
    struct Database: Codable, Sendable {
        let name: String
        let fileByteCount: Int64
        let health: MacClippyDatabaseHealthReport
        let rowCount: Int64?
    }

    struct BlobSummary: Codable, Sendable {
        let fileCount: Int
        let totalByteCount: Int64
        let invalidFileCount: Int
    }

    struct Permissions: Codable, Sendable {
        let accessibilityTrusted: Bool
        let launchAtLoginStatus: String
        let inputMonitoringStatus: String
    }

    struct Preferences: Codable, Sendable {
        let captureAll: Bool
        let privacyPause: Bool
        let excludedAppCount: Int
        let excludedPatternCount: Int
    }

    let generatedAt: Date
    let bundleIdentifier: String
    let version: String
    let build: String
    let operatingSystem: String
    let permissions: Permissions
    let preferences: Preferences
    let databases: [Database]
    let blobs: BlobSummary
    let recentEvents: [MacClippyDiagnosticsEvent]
    let metrics: [String: MacClippyDiagnosticsMetric]
}

struct MacClippyDiagnosticsStorageSnapshot: Sendable {
    let databaseHealth: [String: MacClippyDatabaseHealthReport]
    let databaseRowCounts: [String: Int64]
}

enum MacClippyDiagnosticsExporter {
    static func export(
        to url: URL,
        defaults: UserDefaults = .standard,
        storageSnapshot: MacClippyDiagnosticsStorageSnapshot? = nil
    ) throws {
        let paths = try MacClippyPaths()
        let databaseDefinitions: [(String, URL, Set<String>, String)] = [
            ("clipboard", paths.clipboardDatabaseURL, [
                "clipboard_records",
                "clipboard_representations",
                "clipboard_deletion_operations",
                "clipboard_deletion_journal",
                "clipboard_deletion_records",
                "grdb_migrations"
            ], "clipboard_records"),
            ("search", paths.searchDatabaseURL, ["macclippy_search_index", "macclippy_search_keys", "grdb_migrations"], "macclippy_search_keys"),
            ("pinboards", paths.pinboardDatabaseURL, ["macclippy_pinboards", "grdb_migrations"], "macclippy_pinboards"),
            ("snippets", paths.snippetDatabaseURL, ["macclippy_snippets", "grdb_migrations"], "macclippy_snippets")
        ]
        let databases = databaseDefinitions.compactMap { name, url, requiredTables, rowTable -> MacClippyDiagnosticsExport.Database? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            let database = storageSnapshot == nil ? try? MacClippyDatabase(url: url) : nil
            return MacClippyDiagnosticsExport.Database(
                name: name,
                fileByteCount: Int64(values?.fileSize ?? 0),
                health: storageSnapshot?.databaseHealth[name]
                    ?? database?.healthCheck(requiredTables: requiredTables)
                    ?? MacClippyDatabaseHealthReport(
                        status: .unrecoverable,
                        quickCheckPassed: false,
                        foreignKeyViolationCount: 0,
                        missingTables: [],
                        issues: ["database-open-failed"]
                    ),
                rowCount: storageSnapshot?.databaseRowCounts[name] ?? database?.tableRowCount(rowTable)
            )
        }

        let blobSummary = summarizeBlobs(at: paths.blobsURL)
        let excludedApps = defaults.string(forKey: MacClippyRetentionPreferences.excludedAppsKey)?
            .split(separator: ",")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count ?? 0
        let excludedPatterns = defaults.string(forKey: MacClippyRetentionPreferences.excludedTextPatternsKey)?
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count ?? 0
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let export = MacClippyDiagnosticsExport(
            generatedAt: Date(),
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            operatingSystem: "macOS \(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            permissions: .init(
                accessibilityTrusted: AXIsProcessTrusted(),
                launchAtLoginStatus: String(describing: SMAppService.mainApp.status),
                inputMonitoringStatus: CGPreflightListenEventAccess() ? "enabled" : "not-enabled"
            ),
            preferences: .init(
                captureAll: defaults.bool(forKey: MacClippyRetentionPreferences.captureAllKey),
                privacyPause: defaults.bool(forKey: MacClippyRetentionPreferences.privacyPauseKey),
                excludedAppCount: excludedApps,
                excludedPatternCount: excludedPatterns
            ),
            databases: databases,
            blobs: blobSummary,
            recentEvents: MacClippyDiagnosticsRecorder.shared.recentEvents(),
            metrics: MacClippyDiagnosticsRecorder.shared.metricSnapshot()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(export).write(to: url, options: .atomic)
    }

    private static func summarizeBlobs(at url: URL) -> MacClippyDiagnosticsExport.BlobSummary {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return .init(fileCount: 0, totalByteCount: 0, invalidFileCount: 0)
        }
        var fileCount = 0
        var totalByteCount: Int64 = 0
        var invalidFileCount = 0
        for file in urls {
            guard file.pathExtension == "bin" else {
                invalidFileCount += 1
                continue
            }
            fileCount += 1
            totalByteCount += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return .init(fileCount: fileCount, totalByteCount: totalByteCount, invalidFileCount: invalidFileCount)
    }
}
