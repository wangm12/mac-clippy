import CryptoKit
import Foundation
import XCTest

@testable import MacClippyCore

final class MacClippyBackupRestoreTransactionTests: XCTestCase {
    func testRestoreRollsBackEveryInstalledComponentAfterInjectedIOFailure() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = testKey()
        let snapshotURL = try makeBackupSnapshot(in: root, key: key)
        let components = ["databases", "blobs", "thumbnails"]

        for failedComponent in components {
            let liveRoot = root.appendingPathComponent("live-\(failedComponent)", isDirectory: true)
            try seedLiveRoot(liveRoot)
            XCTAssertThrowsError(
                try MacClippyBackup.installIntoLiveRoot(
                    from: snapshotURL,
                    liveRootURL: liveRoot,
                    deviceKey: key,
                    faultInjector: { point in
                        if point == .afterInstall(failedComponent) {
                            throw NSError(domain: "RestoreIOFailure", code: 1)
                        }
                    }
                )
            )
            assertOldLiveRootRestored(liveRoot)
        }
    }

    func testInterruptedRestoreRecoversOldRootIdempotently() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = testKey()
        let snapshotURL = try makeBackupSnapshot(in: root, key: key)
        let liveRoot = root.appendingPathComponent("live-interrupted", isDirectory: true)
        try seedLiveRoot(liveRoot)

        XCTAssertThrowsError(
            try MacClippyBackup.installIntoLiveRoot(
                from: snapshotURL,
                liveRootURL: liveRoot,
                deviceKey: key,
                faultInjector: { point in
                    if point == .afterInstall("databases") {
                        throw MacClippyBackupError.restoreInterrupted
                    }
                }
            )
        ) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .restoreInterrupted)
        }
        let journalURL = liveRoot.appendingPathComponent(".macclippy-restore-journal.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        try MacClippyBackup.recoverPendingRestore(at: liveRoot)
        try MacClippyBackup.recoverPendingRestore(at: liveRoot)
        assertOldLiveRootRestored(liveRoot)
    }

    func testRestoreKeepsRollbackCopyUntilNewRuntimeStorageOpens() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = testKey()
        let snapshotURL = try makeBackupSnapshot(in: root, key: key)
        let liveRoot = root.appendingPathComponent("live-finalize", isDirectory: true)
        try seedLiveRoot(liveRoot)

        _ = try MacClippyBackup.installIntoLiveRoot(
            from: snapshotURL,
            liveRootURL: liveRoot,
            deviceKey: key
        )
        let journalURL = liveRoot.appendingPathComponent(".macclippy-restore-journal.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        let transactionFolders = try FileManager.default.contentsOfDirectory(
            at: liveRoot,
            includingPropertiesForKeys: nil
        )
            .filter {
                $0.lastPathComponent.hasPrefix(".macclippy-restore-")
                    && !$0.lastPathComponent.hasSuffix(".json")
            }
        XCTAssertEqual(transactionFolders.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: transactionFolders[0].appendingPathComponent("previous/databases/old.txt").path
            )
        )

        // The caller opens all four new database queues before this commit.
        try MacClippyBackup.finalizePendingRestore(at: liveRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
        let oldDatabaseURL = liveRoot.appendingPathComponent("databases/old.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldDatabaseURL.path))
    }

    func testRecoveryCanResumeAfterRollbackAndCleanupInterruptions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = testKey()
        let snapshotURL = try makeBackupSnapshot(in: root, key: key)
        let faultPoints: [MacClippyBackup.RestoreFaultPoint] = [
            .afterRollback("databases"),
            .afterRollbackCommit,
            .beforeTransactionCleanup,
            .afterTransactionCleanup,
            .beforeJournalCleanup
        ]

        for (index, faultPoint) in faultPoints.enumerated() {
            let liveRoot = root.appendingPathComponent("recovery-\(index)", isDirectory: true)
            try seedLiveRoot(liveRoot)
            XCTAssertThrowsError(
                try MacClippyBackup.installIntoLiveRoot(
                    from: snapshotURL,
                    liveRootURL: liveRoot,
                    deviceKey: key,
                    faultInjector: { point in
                        if point == .afterInstall("blobs") {
                            throw MacClippyBackupError.restoreInterrupted
                        }
                    }
                )
            )
            XCTAssertThrowsError(
                try MacClippyBackup.recoverPendingRestore(
                    at: liveRoot,
                    faultInjector: { point in
                        if point == faultPoint {
                            throw MacClippyBackupError.restoreInterrupted
                        }
                    }
                )
            ) { error in
                XCTAssertEqual(error as? MacClippyBackupError, .restoreInterrupted)
            }

            try MacClippyBackup.recoverPendingRestore(at: liveRoot)
            assertOldLiveRootRestored(liveRoot)
        }
    }

    private func makeBackupSnapshot(
        in root: URL,
        key: SymmetricKey,
        includeClipboardRecord: Bool = true
    ) throws -> URL {
        let clipboardDatabase = try MacClippyDatabase(inMemory: true)
        let clipboard = try ClipboardStore(database: clipboardDatabase, deviceKey: key)
        let searchDatabase = try MacClippyDatabase(inMemory: true)
        let search = try SearchStore(database: searchDatabase)
        let pinboardDatabase = try MacClippyDatabase(inMemory: true)
        _ = try PinboardStore(database: pinboardDatabase, deviceKey: key)
        let snippetsDatabase = try MacClippyDatabase(inMemory: true)
        _ = try SnippetStore(database: snippetsDatabase, deviceKey: key)
        if includeClipboardRecord {
            let meta = try clipboard.append(.text("backup regression sample"))
            try search.insert(id: meta.id, text: "backup regression sample")
        }

        let blobsURL = root.appendingPathComponent("source-blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobsURL, withIntermediateDirectories: true)
        let snapshotURL = root.appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: true)
        _ = try MacClippyBackup.create(
            sources: [
                MacClippyBackupSource(name: "clipboard", database: clipboardDatabase),
                MacClippyBackupSource(name: "search", database: searchDatabase),
                MacClippyBackupSource(name: "pinboards", database: pinboardDatabase),
                MacClippyBackupSource(name: "snippets", database: snippetsDatabase)
            ],
            blobsURL: blobsURL,
            deviceKey: key,
            at: snapshotURL
        )
        try [clipboardDatabase, searchDatabase, pinboardDatabase, snippetsDatabase].forEach { try $0.queue.close() }
        return snapshotURL
    }

    private func seedLiveRoot(_ liveRoot: URL) throws {
        for component in ["databases", "blobs", "thumbnails"] {
            let directory = liveRoot.appendingPathComponent(component, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("old-\(component)".utf8).write(to: directory.appendingPathComponent("old.txt"))
        }
    }

    private func assertOldLiveRootRestored(_ liveRoot: URL, file: StaticString = #filePath, line: UInt = #line) {
        for component in ["databases", "blobs", "thumbnails"] {
            let marker = liveRoot.appendingPathComponent(component).appendingPathComponent("old.txt")
            XCTAssertEqual(try? Data(contentsOf: marker), Data("old-\(component)".utf8), file: file, line: line)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: liveRoot.appendingPathComponent(".macclippy-restore-journal.json").path
            ),
            file: file,
            line: line
        )
    }

    private func testKey() -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 7, count: 32))
    }

    private func temporaryDirectory() throws -> URL {
        let name = "MacClippyRecoveryTests-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
