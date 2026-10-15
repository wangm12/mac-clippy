import CryptoKit
import Foundation
import XCTest

@testable import MacClippyCore

private struct HistoricalBackupRestoreFixture {
    let root: URL
    let key: SymmetricKey
    let snapshotURL: URL
    let originalBackupBytes: [String: Data]
}

final class MacClippyBackupHistoricalSchemaTests: XCTestCase {
    func testMigration008BackupValidatesReadOnlyAndInstallsLegacyRows() throws {
        let fixture = try makeHistoricalRestoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let liveRoot = fixture.root.appendingPathComponent("live-root", isDirectory: true)
        try MacClippyBackupHistoricalSchemaFixture.makePriorLiveRoot(at: liveRoot, key: fixture.key)
        let priorLiveBytes = try MacClippyBackupHistoricalSchemaFixture.snapshotBytes(at: liveRoot)
        try assertRejectedInstallsPreserveData(
            from: fixture.snapshotURL,
            into: liveRoot,
            key: fixture.key,
            originalBackupBytes: fixture.originalBackupBytes,
            priorLiveBytes: priorLiveBytes
        )

        _ = try MacClippyBackup.installIntoLiveRoot(
            from: fixture.snapshotURL,
            liveRootURL: liveRoot,
            deviceKey: fixture.key
        )
        try assertBackupUnchanged(fixture)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: liveRoot.appendingPathComponent(MacClippyBackup.restoreJournalFileName).path
        ))

        try assertRestoredClipboard(at: liveRoot, key: fixture.key)
        try assertRestoredHistoricalSearch(at: liveRoot)
        try MacClippyBackup.finalizePendingRestore(at: liveRoot)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: liveRoot.appendingPathComponent(MacClippyBackup.restoreJournalFileName).path
        ))
        try assertBackupUnchanged(fixture)
    }
}

private extension MacClippyBackupHistoricalSchemaTests {
    func makeHistoricalRestoreFixture() throws -> HistoricalBackupRestoreFixture {
        let root = try makeTemporaryRoot()
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let snapshotURL = try MacClippyBackupHistoricalSchemaFixture.makeMigration008Backup(
            in: root,
            key: key
        )
        let originalBackupBytes = try MacClippyBackupHistoricalSchemaFixture.snapshotBytes(at: snapshotURL)
        try assertBackupValidation(at: snapshotURL, key: key, originalBytes: originalBackupBytes)
        return HistoricalBackupRestoreFixture(
            root: root,
            key: key,
            snapshotURL: snapshotURL,
            originalBackupBytes: originalBackupBytes
        )
    }

    func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyHistoricalBackup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func assertBackupUnchanged(_ fixture: HistoricalBackupRestoreFixture) throws {
        XCTAssertEqual(
            try MacClippyBackupHistoricalSchemaFixture.snapshotBytes(at: fixture.snapshotURL),
            fixture.originalBackupBytes
        )
    }

    private func assertBackupValidation(
        at snapshotURL: URL,
        key: SymmetricKey,
        originalBytes: [String: Data]
    ) throws {
        let validation = try MacClippyBackup.validate(at: snapshotURL, deviceKey: key)
        XCTAssertTrue(validation.keyCompatible)
        XCTAssertEqual(validation.manifest.formatVersion, 1)
        XCTAssertEqual(validation.databaseRowCounts["clipboard"], 2)

        let unkeyedValidation = try MacClippyBackup.validate(at: snapshotURL)
        XCTAssertFalse(unkeyedValidation.keyCompatible)
        let wrongKey = SymmetricKey(data: Data(repeating: 9, count: 32))
        XCTAssertThrowsError(try MacClippyBackup.validate(at: snapshotURL, deviceKey: wrongKey)) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .keyMismatch)
        }
        XCTAssertEqual(
            try MacClippyBackupHistoricalSchemaFixture.snapshotBytes(at: snapshotURL),
            originalBytes
        )
    }

    private func assertRejectedInstallsPreserveData(
        from snapshotURL: URL,
        into liveRoot: URL,
        key: SymmetricKey,
        originalBackupBytes: [String: Data],
        priorLiveBytes: [String: Data]
    ) throws {
        let wrongKey = SymmetricKey(data: Data(repeating: 9, count: 32))
        XCTAssertThrowsError(try MacClippyBackup.installIntoLiveRoot(
            from: snapshotURL,
            liveRootURL: liveRoot,
            deviceKey: nil,
            faultInjector: nil
        )) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .keyRequired)
        }
        XCTAssertThrowsError(try MacClippyBackup.installIntoLiveRoot(
            from: snapshotURL,
            liveRootURL: liveRoot,
            deviceKey: wrongKey
        )) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .keyMismatch)
        }

        XCTAssertEqual(
            try MacClippyBackupHistoricalSchemaFixture.snapshotBytes(at: liveRoot),
            priorLiveBytes
        )
        XCTAssertEqual(
            try MacClippyBackupHistoricalSchemaFixture.snapshotBytes(at: snapshotURL),
            originalBackupBytes
        )
        let priorStore = try MacClippyBackupHistoricalSchemaFixture.readClipboardStore(at: liveRoot, key: key)
        defer { try? priorStore.database.queue.close() }
        XCTAssertEqual(try priorStore.list(limit: 10).map(\.preview), ["prior live data"])
    }

    private func assertRestoredClipboard(at liveRoot: URL, key: SymmetricKey) throws {
        let restoredStore = try MacClippyBackupHistoricalSchemaFixture.readClipboardStore(at: liveRoot, key: key)
        defer { try? restoredStore.database.queue.close() }

        let history = try restoredStore.list(limit: 10)
        XCTAssertEqual(
            Set(history.map(\.id.rawValue)),
            [
                MacClippyBackupHistoricalSchemaFixture.historicalRecordID,
                MacClippyBackupHistoricalSchemaFixture.historicalImageRecordID
            ]
        )
        XCTAssertTrue(history.contains {
            $0.id.rawValue == MacClippyBackupHistoricalSchemaFixture.historicalRecordID
                && $0.preview == "migration 008 historical body"
                && $0.contentKind == .text
        })
        XCTAssertTrue(history.contains {
            $0.id.rawValue == MacClippyBackupHistoricalSchemaFixture.historicalImageRecordID
                && $0.preview == "historical image"
                && $0.contentKind == .image
        })

        let textID = try XCTUnwrap(RecordID(
            rawValue: MacClippyBackupHistoricalSchemaFixture.historicalRecordID
        ))
        XCTAssertEqual(try restoredStore.body(for: textID), .text("migration 008 historical body"))
        try assertRestoredImage(on: restoredStore, at: liveRoot, key: key)
    }

    private func assertRestoredImage(on store: ClipboardStore, at liveRoot: URL, key: SymmetricKey) throws {
        let imageID = try XCTUnwrap(RecordID(
            rawValue: MacClippyBackupHistoricalSchemaFixture.historicalImageRecordID
        ))
        XCTAssertEqual(
            try store.body(for: imageID),
            .image(blobID: MacClippyBackupHistoricalSchemaFixture.historicalImageBlobID, width: 2, height: 1)
        )

        let snapshot = try store.playbackSnapshot(for: imageID)
        XCTAssertEqual(snapshot.representations.map(\.uti), ["public.png", "com.example.legacy-spill"])
        let inline = try XCTUnwrap(snapshot.representations.first { $0.uti == "public.png" })
        XCTAssertEqual(inline.payloadState, .present)
        XCTAssertEqual(inline.payloadBytes, MacClippyBackupHistoricalSchemaFixture.historicalImageBytes)
        XCTAssertNil(inline.blobID)
        let spilled = try XCTUnwrap(snapshot.representations.first { $0.uti == "com.example.legacy-spill" })
        XCTAssertEqual(spilled.payloadState, .spilled)
        XCTAssertNil(spilled.payloadBytes)
        XCTAssertEqual(spilled.blobID, MacClippyBackupHistoricalSchemaFixture.historicalSpillBlobID)

        let blobs = try BlobStore(
            rootURL: liveRoot.appendingPathComponent("blobs", isDirectory: true),
            key: key
        )
        XCTAssertEqual(
            try blobs.read(id: MacClippyBackupHistoricalSchemaFixture.historicalImageBlobID),
            MacClippyBackupHistoricalSchemaFixture.historicalImageBytes
        )
        XCTAssertEqual(
            try blobs.read(id: MacClippyBackupHistoricalSchemaFixture.historicalSpillBlobID),
            MacClippyBackupHistoricalSchemaFixture.historicalSpillBytes
        )
    }

    private func assertRestoredHistoricalSearch(at liveRoot: URL) throws {
        let migrated = try MacClippyBackupHistoricalSchemaFixture.readSearchStore(at: liveRoot)
        XCTAssertEqual(try migrated.databaseRowCount(), 1)
        try migrated.database.queue.close()

        let reopened = try MacClippyBackupHistoricalSchemaFixture.readSearchStore(at: liveRoot)
        defer { try? reopened.database.queue.close() }
        let historicalID = try XCTUnwrap(RecordID(
            rawValue: MacClippyBackupHistoricalSchemaFixture.historicalRecordID
        ))
        XCTAssertEqual(try reopened.search(query: "migration needle", limit: 10).map(\.id), [historicalID])
    }
}
