import ApplicationServices
import AppKit
import Foundation
import ServiceManagement

import MacClippyCore

struct MacClippyDiagnosticsExport: Codable, Sendable {
    struct Database: Codable, Sendable {
        let name: String
        let fileByteCount: Int64
        let fileSizeIssue: String?
        let health: MacClippyDatabaseHealthReport
        let rowCount: Int64?
        let rowCountIssue: String?
    }

    struct BlobSummary: Codable, Sendable {
        let fileCount: Int
        let totalByteCount: Int64
        let invalidFileCount: Int
        let fileSizeErrorCount: Int
        let scanIssue: String?
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
    let databaseRowCountIssues: [String: String]
}

enum MacClippyDiagnosticsExporter {
    static func export(
        to url: URL,
        defaults: UserDefaults = .standard,
        storageSnapshot: MacClippyDiagnosticsStorageSnapshot? = nil
    ) throws {
        let paths = try MacClippyPaths()
        let databases = buildDatabases(at: paths, storageSnapshot: storageSnapshot)

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
            recentEvents: recentDiagnosticEvents(),
            metrics: MacClippyDiagnosticsRecorder.shared.metricSnapshot()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(export).write(to: url, options: .atomic)
    }

    private static func recentDiagnosticEvents() -> [MacClippyDiagnosticsEvent] {
        let persisted = MacClippyDiagnosticsJournal.shared.recentEvents()
        return persisted.isEmpty ? MacClippyDiagnosticsRecorder.shared.recentEvents() : persisted
    }

    private struct DatabaseDefinition {
        let name: String
        let url: URL
        let requiredTables: Set<String>
        let rowTable: String
    }

    private static func buildDatabases(
        at paths: MacClippyPaths,
        storageSnapshot: MacClippyDiagnosticsStorageSnapshot?
    ) -> [MacClippyDiagnosticsExport.Database] {
        let definitions = [
            DatabaseDefinition(name: "clipboard", url: paths.clipboardDatabaseURL, requiredTables: [
                "clipboard_records", "clipboard_representations", "clipboard_deletion_operations",
                "clipboard_deletion_journal", "clipboard_deletion_records", "grdb_migrations"
            ], rowTable: "clipboard_records"),
            DatabaseDefinition(name: "search", url: paths.searchDatabaseURL, requiredTables: [
                "macclippy_search_index", "macclippy_search_keys", "grdb_migrations"
            ], rowTable: "macclippy_search_keys"),
            DatabaseDefinition(name: "pinboards", url: paths.pinboardDatabaseURL, requiredTables: [
                "macclippy_pinboards", "grdb_migrations"
            ], rowTable: "macclippy_pinboards"),
            DatabaseDefinition(name: "snippets", url: paths.snippetDatabaseURL, requiredTables: [
                "macclippy_snippets", "grdb_migrations"
            ], rowTable: "macclippy_snippets")
        ]
        return definitions.compactMap { definition in
            makeDatabaseReport(for: definition, storageSnapshot: storageSnapshot)
        }
    }

    private static func makeDatabaseReport(
        for definition: DatabaseDefinition,
        storageSnapshot: MacClippyDiagnosticsStorageSnapshot?
    ) -> MacClippyDiagnosticsExport.Database? {
        guard FileManager.default.fileExists(atPath: definition.url.path) else { return nil }
        let values: URLResourceValues?
        let fileSizeIssue: String?
        do {
            values = try definition.url.resourceValues(forKeys: [.fileSizeKey])
            fileSizeIssue = values?.fileSize == nil ? "database-file-size-unavailable" : nil
        } catch {
            values = nil
            fileSizeIssue = "database-file-size-query-failed"
        }

        let database: MacClippyDatabase?
        if storageSnapshot == nil {
            do { database = try MacClippyDatabase(url: definition.url) } catch { database = nil }
        } else {
            database = nil
        }
        let rowCount: Int64?
        let rowCountIssue: String?
        if let storageSnapshot {
            rowCount = storageSnapshot.databaseRowCounts[definition.name]
            rowCountIssue = storageSnapshot.databaseRowCountIssues[definition.name]
        } else if let database {
            do {
                let value = try database.tableRowCount(definition.rowTable)
                rowCount = value
                rowCountIssue = value == nil ? "row-count-unavailable" : nil
            } catch {
                rowCount = nil
                rowCountIssue = "row-count-query-failed"
            }
        } else {
            rowCount = nil
            rowCountIssue = "database-open-failed"
        }
        return MacClippyDiagnosticsExport.Database(
            name: definition.name,
            fileByteCount: Int64(values?.fileSize ?? 0),
            fileSizeIssue: fileSizeIssue,
            health: storageSnapshot?.databaseHealth[definition.name]
                ?? database?.healthCheck(requiredTables: definition.requiredTables)
                ?? MacClippyDatabaseHealthReport(
                    status: .unrecoverable,
                    quickCheckPassed: false,
                    foreignKeyViolationCount: 0,
                    missingTables: [],
                    issues: ["database-open-failed"]
                ),
            rowCount: rowCount,
            rowCountIssue: rowCountIssue
        )
    }

    private static func summarizeBlobs(at url: URL) -> MacClippyDiagnosticsExport.BlobSummary {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return .init(
                fileCount: 0,
                totalByteCount: 0,
                invalidFileCount: 0,
                fileSizeErrorCount: 0,
                scanIssue: "blob-directory-missing"
            )
        }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])
        } catch {
            return .init(
                fileCount: 0,
                totalByteCount: 0,
                invalidFileCount: 0,
                fileSizeErrorCount: 0,
                scanIssue: "blob-directory-read-failed"
            )
        }
        var fileCount = 0
        var totalByteCount: Int64 = 0
        var invalidFileCount = 0
        var fileSizeErrorCount = 0
        for file in urls {
            guard file.pathExtension == "bin" else {
                invalidFileCount += 1
                continue
            }
            fileCount += 1
            do {
                guard let fileSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    fileSizeErrorCount += 1
                    continue
                }
                totalByteCount += Int64(fileSize)
            } catch {
                fileSizeErrorCount += 1
            }
        }
        return .init(
            fileCount: fileCount,
            totalByteCount: totalByteCount,
            invalidFileCount: invalidFileCount,
            fileSizeErrorCount: fileSizeErrorCount,
            scanIssue: fileSizeErrorCount > 0 ? "blob-file-size-query-failed" : nil
        )
    }
}
