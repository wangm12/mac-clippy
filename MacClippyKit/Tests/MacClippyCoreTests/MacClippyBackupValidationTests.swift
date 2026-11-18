import CryptoKit
import Foundation
import XCTest

@testable import MacClippyCore

final class MacClippyBackupValidationTests: XCTestCase {
    func testBackupValidationAndRestorePreserveDatabaseAndBlobEvidence() throws {
        let root = try BackupValidationFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = BackupValidationFixture.testKey()
        let snapshotURL = try BackupValidationFixture.makeBackupSnapshot(
            in: root,
            key: key,
            includeBlob: true
        )
        let validation = try MacClippyBackup.validate(at: snapshotURL, deviceKey: key)
        XCTAssertEqual(validation.databaseHealth["clipboard"]?.status, .healthy)
        XCTAssertEqual(validation.databaseHealth["search"]?.status, .healthy)
        XCTAssertEqual(validation.databaseRowCounts["clipboard"], 2)
        XCTAssertEqual(validation.databaseRowCounts["search"], 2)
        XCTAssertTrue(validation.manifest.files.contains { $0.relativePath == "blobs/fixture-image.bin" })

        let restoredURL = root.appendingPathComponent("restored", isDirectory: true)
        let restored = try MacClippyBackup.restore(from: snapshotURL, to: restoredURL)
        XCTAssertEqual(restored.databaseRowCounts, validation.databaseRowCounts)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: restoredURL.appendingPathComponent("blobs/fixture-image.bin").path
            )
        )

        try assertLiveRestore(snapshotURL: snapshotURL, root: root, key: key, rows: validation.databaseRowCounts)
    }

    private func assertLiveRestore(
        snapshotURL: URL,
        root: URL,
        key: SymmetricKey,
        rows: [String: Int64]
    ) throws {
        let liveRoot = root.appendingPathComponent("live", isDirectory: true)
        try FileManager.default.createDirectory(
            at: liveRoot.appendingPathComponent("thumbnails", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("thumb".utf8).write(to: liveRoot.appendingPathComponent("thumbnails/old.bin"))

        let installed = try MacClippyBackup.installIntoLiveRoot(
            from: snapshotURL,
            liveRootURL: liveRoot,
            deviceKey: key
        )
        try MacClippyBackup.finalizePendingRestore(at: liveRoot)
        XCTAssertEqual(installed.databaseRowCounts, rows)
        XCTAssertTrue(
            FileManager.default.fileExists(
            atPath: liveRoot.appendingPathComponent("databases/clipboard.sqlite").path
        )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: liveRoot.appendingPathComponent("blobs/fixture-image.bin").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: liveRoot.appendingPathComponent("thumbnails/old.bin").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: liveRoot.appendingPathComponent("clipboard.sqlite").path
            )
        )
    }

    func testBackupCreationRejectsMissingBodyAndRepresentationBlobs() throws {
        let root = try BackupValidationFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try BackupValidationFixture.makeBackupSnapshot(
                in: root,
                key: BackupValidationFixture.testKey(),
                missingBodyBlob: true
            )
        ) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .missingComponent("blobs/missing-image.bin"))
        }
        XCTAssertThrowsError(
            try BackupValidationFixture.makeBackupSnapshot(
                in: root,
                key: BackupValidationFixture.testKey(),
                missingRepresentationBlob: true
            )
        ) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .missingComponent("blobs/missing-representation.bin"))
        }
    }

    func testBackupValidationRejectsUnlistedReferencedBodyAndRepresentationBlobs() throws {
        for missingBlob in ["fixture-image", "fixture-representation"] {
            let root = try BackupValidationFixture.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let key = BackupValidationFixture.testKey()
            let snapshotURL = try BackupValidationFixture.makeBackupSnapshot(
                in: root,
                key: key,
                includeBlob: true,
                includeRepresentationBlob: true
            )
            let blobPath = "blobs/\(missingBlob).bin"
            try FileManager.default.removeItem(at: snapshotURL.appendingPathComponent(blobPath))
            let manifestURL = snapshotURL.appendingPathComponent(MacClippyBackup.manifestFileName)
            let manifest = try JSONDecoder().decode(MacClippyBackupManifest.self, from: Data(contentsOf: manifestURL))
            let incompleteManifest = MacClippyBackupManifest(
                formatVersion: manifest.formatVersion,
                createdAt: manifest.createdAt,
                databaseNames: manifest.databaseNames,
                files: manifest.files.filter { $0.relativePath != blobPath },
                keyCheck: manifest.keyCheck
            )
            try JSONEncoder().encode(incompleteManifest).write(to: manifestURL, options: .atomic)

            XCTAssertThrowsError(try MacClippyBackup.validate(at: snapshotURL, deviceKey: key)) { error in
                XCTAssertEqual(error as? MacClippyBackupError, .missingComponent(blobPath))
            }
        }
    }

    func testBackupValidationRejectsSameLengthDatabaseCorruption() throws {
        let root = try BackupValidationFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = BackupValidationFixture.testKey()
        let snapshotURL = try BackupValidationFixture.makeBackupSnapshot(in: root, key: key)
        let clipboardURL = snapshotURL.appendingPathComponent("clipboard.sqlite")
        let database = try MacClippyDatabase(url: clipboardURL)
        try database.queue.write { connection in
            try connection.execute(sql: "UPDATE clipboard_records SET envelope = zeroblob(length(envelope))")
        }
        try database.queue.close()

        XCTAssertThrowsError(try MacClippyBackup.validate(at: snapshotURL, deviceKey: key)) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .checksumMismatch("clipboard.sqlite"))
        }
    }

    func testBackupValidationIsReadOnlyAcrossRepeatedChecks() throws {
        let root = try BackupValidationFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = BackupValidationFixture.testKey()
        let snapshotURL = try BackupValidationFixture.makeBackupSnapshot(in: root, key: key)
        let manifest = try JSONDecoder().decode(
            MacClippyBackupManifest.self,
            from: Data(contentsOf: snapshotURL.appendingPathComponent(MacClippyBackup.manifestFileName))
        )
        let before = try Dictionary(uniqueKeysWithValues: manifest.files.map { entry in
            (entry.relativePath, try Data(contentsOf: snapshotURL.appendingPathComponent(entry.relativePath)))
        })

        _ = try MacClippyBackup.validate(at: snapshotURL, deviceKey: key)
        _ = try MacClippyBackup.validate(at: snapshotURL, deviceKey: key)

        for (path, bytes) in before {
            XCTAssertEqual(try Data(contentsOf: snapshotURL.appendingPathComponent(path)), bytes, path)
        }
        for name in MacClippyBackupSettingsPolicy.requiredDatabaseNames {
            let path = snapshotURL.appendingPathComponent("\(name).sqlite").path
            XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-wal"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: path + "-shm"))
        }
    }

    func testBackupValidationRejectsFileAndDirectorySymlinks() throws {
        let root = try BackupValidationFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = BackupValidationFixture.testKey()
        let snapshotURL = try BackupValidationFixture.makeBackupSnapshot(in: root, key: key)
        let manifestURL = snapshotURL.appendingPathComponent(MacClippyBackup.manifestFileName)
        let manifest = try JSONDecoder().decode(
            MacClippyBackupManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let linkedBlobURL = snapshotURL.appendingPathComponent("blobs/linked.bin")
        let targetURL = snapshotURL.appendingPathComponent("clipboard.sqlite")
        try FileManager.default.createSymbolicLink(at: linkedBlobURL, withDestinationURL: targetURL)
        let linkedManifest = MacClippyBackupManifest(
            formatVersion: manifest.formatVersion,
            createdAt: manifest.createdAt,
            databaseNames: manifest.databaseNames,
            files: manifest.files + [.init(relativePath: "blobs/linked.bin", byteCount: 0, sha256: "")],
            keyCheck: manifest.keyCheck
        )
        try JSONEncoder().encode(linkedManifest).write(to: manifestURL, options: .atomic)

        XCTAssertThrowsError(try MacClippyBackup.validate(at: snapshotURL, deviceKey: key)) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .invalidManifest)
        }

        try FileManager.default.removeItem(at: linkedBlobURL)
        try FileManager.default.removeItem(at: snapshotURL.appendingPathComponent("blobs", isDirectory: true))
        let externalDirectory = root.appendingPathComponent("external-blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: snapshotURL.appendingPathComponent("blobs", isDirectory: true),
            withDestinationURL: externalDirectory
        )

        XCTAssertThrowsError(try MacClippyBackup.validate(at: snapshotURL, deviceKey: key)) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .invalidManifest)
        }
    }

    func testBackupValidationRejectsWrongAndMissingKeysBeforeLiveMutation() throws {
        let root = try BackupValidationFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = BackupValidationFixture.testKey()
        let wrongKey = SymmetricKey(data: Data(repeating: 42, count: 32))
        let snapshotURL = try BackupValidationFixture.makeBackupSnapshot(in: root, key: key)
        XCTAssertThrowsError(try MacClippyBackup.validate(at: snapshotURL, deviceKey: wrongKey)) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .keyMismatch)
        }

        let liveRoot = root.appendingPathComponent("live", isDirectory: true)
        try FileManager.default.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        let oldValue = liveRoot.appendingPathComponent("keep.txt")
        try Data("old-data".utf8).write(to: oldValue)
        XCTAssertThrowsError(
            try MacClippyBackup.installIntoLiveRoot(
                from: snapshotURL,
                liveRootURL: liveRoot,
                deviceKey: nil,
                faultInjector: nil
            )
        ) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .keyRequired)
        }
        XCTAssertEqual(try Data(contentsOf: oldValue), Data("old-data".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: liveRoot.appendingPathComponent(".macclippy-restore-journal.json").path
            )
        )
    }

}

enum BackupValidationFixture {
    private struct Options {
        let includeClipboardRecord: Bool
        let includeBlob: Bool
        let includeRepresentationBlob: Bool
        let missingBodyBlob: Bool
        let missingRepresentationBlob: Bool
    }

    private struct Stores {
        let clipboardDatabase: MacClippyDatabase
        let clipboard: ClipboardStore
        let searchDatabase: MacClippyDatabase
        let search: SearchStore
        let pinboardsDatabase: MacClippyDatabase
        let snippetsDatabase: MacClippyDatabase

        var sources: [MacClippyBackupSource] {
            [
                MacClippyBackupSource(name: "clipboard", database: clipboardDatabase),
                MacClippyBackupSource(name: "search", database: searchDatabase),
                MacClippyBackupSource(name: "pinboards", database: pinboardsDatabase),
                MacClippyBackupSource(name: "snippets", database: snippetsDatabase)
            ]
        }

        func close() throws {
            for database in [clipboardDatabase, searchDatabase, pinboardsDatabase, snippetsDatabase] {
                try database.queue.close()
            }
        }
    }

    static func makeBackupSnapshot(
        in root: URL,
        key: SymmetricKey,
        includeClipboardRecord: Bool = true,
        includeBlob: Bool = false,
        includeRepresentationBlob: Bool = false,
        missingBodyBlob: Bool = false,
        missingRepresentationBlob: Bool = false
    ) throws -> URL {
        let options = Options(
            includeClipboardRecord: includeClipboardRecord,
            includeBlob: includeBlob,
            includeRepresentationBlob: includeRepresentationBlob,
            missingBodyBlob: missingBodyBlob,
            missingRepresentationBlob: missingRepresentationBlob
        )
        let stores = try makeStores(key: key)
        let blobsURL = root.appendingPathComponent("source-blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobsURL, withIntermediateDirectories: true)
        try populate(stores: stores, key: key, blobsURL: blobsURL, options: options)
        let snapshotURL = root.appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: true)
        _ = try MacClippyBackup.create(
            sources: stores.sources,
            blobsURL: blobsURL,
            deviceKey: key,
            at: snapshotURL
        )
        try stores.close()
        return snapshotURL
    }

    private static func makeStores(key: SymmetricKey) throws -> Stores {
        let clipboardDatabase = try MacClippyDatabase(inMemory: true)
        let clipboard = try ClipboardStore(database: clipboardDatabase, deviceKey: key)
        let searchDatabase = try MacClippyDatabase(inMemory: true)
        let search = try SearchStore(database: searchDatabase)
        let pinboardDatabase = try MacClippyDatabase(inMemory: true)
        _ = try PinboardStore(database: pinboardDatabase, deviceKey: key)
        let snippetsDatabase = try MacClippyDatabase(inMemory: true)
        _ = try SnippetStore(database: snippetsDatabase, deviceKey: key)
        return Stores(
            clipboardDatabase: clipboardDatabase,
            clipboard: clipboard,
            searchDatabase: searchDatabase,
            search: search,
            pinboardsDatabase: pinboardDatabase,
            snippetsDatabase: snippetsDatabase
        )
    }

    private static func populate(
        stores: Stores,
        key: SymmetricKey,
        blobsURL: URL,
        options: Options
    ) throws {
        if options.includeClipboardRecord {
            let meta = try stores.clipboard.append(.text("backup regression sample"))
            try stores.search.insert(id: meta.id, text: "backup regression sample")
        }
        if options.includeBlob {
            let blobID = "fixture-image"
            _ = try BlobStore(rootURL: blobsURL, key: key).write(Data("image-payload".utf8), id: blobID)
            let meta = try stores.clipboard.append(.image(blobID: blobID, width: 1, height: 1))
            try stores.search.insert(id: meta.id, text: "fixture image")
        }
        if options.includeRepresentationBlob {
            let blobID = "fixture-representation"
            _ = try BlobStore(rootURL: blobsURL, key: key).write(Data("representation-payload".utf8), id: blobID)
            _ = try stores.clipboard.append(
                .text("stored representation fixture"),
                representations: [
                    MacClippyClipboardRepresentation(uti: "public.data", payloadBytes: nil, blobID: blobID)
                ]
            )
        }
        if options.missingBodyBlob {
            _ = try stores.clipboard.append(.image(blobID: "missing-image", width: 1, height: 1))
        }
        if options.missingRepresentationBlob {
            _ = try stores.clipboard.append(
                .text("representation fixture"),
                representations: [
                    MacClippyClipboardRepresentation(
                        uti: "public.data",
                        payloadBytes: nil,
                        blobID: "missing-representation"
                    )
                ]
            )
        }
    }

    static func testKey() -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 7, count: 32))
    }

    static func temporaryDirectory() throws -> URL {
        let directoryName = "MacClippyRecoveryTests-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
