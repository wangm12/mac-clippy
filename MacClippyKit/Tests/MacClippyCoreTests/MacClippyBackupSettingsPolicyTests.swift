import XCTest

@testable import MacClippyCore

final class MacClippyBackupSettingsPolicyTests: XCTestCase {
    func testSuggestedFolderNameUsesAStableDatedPrefix() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_725_321_600)
        XCTAssertEqual(
            MacClippyBackupSettingsPolicy.suggestedFolderName(now: now, timeZone: calendar.timeZone),
            "MacClippy-Backup-2024-09-03"
        )
    }

    func testInstallOperationsMapSnapshotFilesOntoTheLiveLayout() {
        let operations = MacClippyBackupSettingsPolicy.installOperations()
        XCTAssertEqual(
            operations,
            [
                .init(
                    sourceRelativePath: "clipboard.sqlite",
                    destinationRelativePath: "databases/clipboard.sqlite",
                    kind: .database
                ),
                .init(
                    sourceRelativePath: "pinboards.sqlite",
                    destinationRelativePath: "databases/pinboards.sqlite",
                    kind: .database
                ),
                .init(
                    sourceRelativePath: "search.sqlite",
                    destinationRelativePath: "databases/search.sqlite",
                    kind: .database
                ),
                .init(
                    sourceRelativePath: "snippets.sqlite",
                    destinationRelativePath: "databases/snippets.sqlite",
                    kind: .database
                ),
                .init(
                    sourceRelativePath: "blobs",
                    destinationRelativePath: "blobs",
                    kind: .directory
                )
            ]
        )
        XCTAssertEqual(
            MacClippyBackupSettingsPolicy.sqliteSidecarRelativePaths(
                for: "databases/clipboard.sqlite"
            ),
            ["databases/clipboard.sqlite-wal", "databases/clipboard.sqlite-shm"]
        )
        XCTAssertEqual(
            MacClippyBackupSettingsPolicy.directoriesToClearOnRestore(),
            [MacClippyThumbnailCachePolicy.directoryName]
        )
    }

    func testRestoreRequiresEveryHealthyDatabase() {
        let healthy = MacClippyDatabaseHealthReport(
            status: .healthy,
            quickCheckPassed: true,
            foreignKeyViolationCount: 0,
            missingTables: [],
            issues: []
        )
        let unrecoverable = MacClippyDatabaseHealthReport(
            status: .unrecoverable,
            quickCheckPassed: false,
            foreignKeyViolationCount: 0,
            missingTables: ["clipboard_records"],
            issues: ["missing-tables"]
        )
        let names = MacClippyBackupSettingsPolicy.requiredDatabaseNames
        let files = names.map {
            MacClippyBackupManifest.FileEntry(relativePath: "\($0).sqlite", byteCount: 1, sha256: "abc")
        }
        let complete = MacClippyBackupValidation(
            manifest: MacClippyBackupManifest(
                formatVersion: 1,
                createdAt: Date(timeIntervalSince1970: 0),
                databaseNames: names,
                files: files
            ),
            databaseHealth: Dictionary(uniqueKeysWithValues: names.map { ($0, healthy) }),
            databaseRowCounts: Dictionary(uniqueKeysWithValues: names.map { ($0, Int64(1)) })
        )
        XCTAssertTrue(MacClippyBackupSettingsPolicy.canRestore(complete))

        let damaged = MacClippyBackupValidation(
            manifest: complete.manifest,
            databaseHealth: ["clipboard": unrecoverable],
            databaseRowCounts: complete.databaseRowCounts
        )
        XCTAssertFalse(MacClippyBackupSettingsPolicy.canRestore(damaged))

        let incomplete = MacClippyBackupValidation(
            manifest: MacClippyBackupManifest(
                formatVersion: 1,
                createdAt: Date(timeIntervalSince1970: 0),
                databaseNames: ["clipboard"],
                files: [files[0]]
            ),
            databaseHealth: ["clipboard": healthy],
            databaseRowCounts: ["clipboard": 1]
        )
        XCTAssertFalse(MacClippyBackupSettingsPolicy.canRestore(incomplete))
    }

    func testReplaceLiveItemCopiesToStagingBeforeReplacingTheDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyBackupReplace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("incoming.sqlite")
        let destination = root.appendingPathComponent("live.sqlite")
        try Data("new-library".utf8).write(to: source)
        try Data("current-library".utf8).write(to: destination)

        try MacClippyBackupSettingsPolicy.replaceLiveItem(at: destination, withContentsOf: source)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new-library")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: MacClippyBackupSettingsPolicy.stagingURL(for: destination).path
            )
        )
    }

    func testReplaceLiveItemLeavesTheDestinationWhenTheSourceIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyBackupReplaceMissing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("missing.sqlite")
        let destination = root.appendingPathComponent("live.sqlite")
        try Data("current-library".utf8).write(to: destination)

        XCTAssertThrowsError(
            try MacClippyBackupSettingsPolicy.replaceLiveItem(at: destination, withContentsOf: source)
        )
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "current-library")
    }

    func testUserFacingMessagesCoverBackupFailures() {
        XCTAssertEqual(
            MacClippyBackupSettingsPolicy.message(for: .destinationExists),
            "A backup already exists at that location. Choose a new folder."
        )
        XCTAssertEqual(
            MacClippyBackupSettingsPolicy.message(for: .invalidManifest),
            "This folder is not a valid MacClippy backup."
        )
        XCTAssertTrue(
            MacClippyBackupSettingsPolicy.message(for: .missingComponent("manifest.json"))
                .contains("manifest.json")
        )
        XCTAssertTrue(
            MacClippyBackupSettingsPolicy.message(for: .checksumMismatch("blobs/a.bin"))
                .contains("blobs/a.bin")
        )
        XCTAssertTrue(MacClippyBackupSettingsPolicy.createSuccessMessage(databaseCount: 4).contains("4"))
        XCTAssertFalse(MacClippyBackupSettingsPolicy.restoreSuccessMessage().isEmpty)
    }
}
