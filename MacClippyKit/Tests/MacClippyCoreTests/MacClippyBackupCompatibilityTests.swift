import CryptoKit
import Foundation
import GRDB
import XCTest

@testable import MacClippyCore

private typealias ClipboardSnapshotMutation = (DatabaseQueue, String, SymmetricKey) throws -> Void

final class MacClippyBackupCompatibilityTests: XCTestCase {
    func testBackupValidationRejectsManifestPathTraversal() throws {
        let root = try BackupValidationFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = MacClippyBackupManifest(
            formatVersion: 1,
            createdAt: Date(),
            databaseNames: ["clipboard"],
            files: [.init(relativePath: "../outside.sqlite", byteCount: 0, sha256: "")]
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: root.appendingPathComponent(MacClippyBackup.manifestFileName))

        XCTAssertThrowsError(try MacClippyBackup.validate(at: root)) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .invalidManifest)
        }
    }

    func testEmptyBackupRequiresAndContainsAnEmptyBlobsDirectory() throws {
        let root = try BackupValidationFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = BackupValidationFixture.testKey()
        let snapshotURL = try BackupValidationFixture.makeBackupSnapshot(
            in: root,
            key: key,
            includeClipboardRecord: false
        )

        let validation = try MacClippyBackup.validate(at: snapshotURL, deviceKey: key)
        XCTAssertTrue(MacClippyBackupSettingsPolicy.canRestore(validation))
        XCTAssertEqual(validation.databaseRowCounts["clipboard"], 0)
        let blobsURL = snapshotURL.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.removeItem(at: blobsURL)
        XCTAssertThrowsError(try MacClippyBackup.validate(at: snapshotURL, deviceKey: key)) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .missingComponent("blobs/"))
        }
    }

    func testLegacyEmptyBackupCannotProveItsKey() throws {
        let root = try BackupValidationFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = BackupValidationFixture.testKey()
        let snapshotURL = try BackupValidationFixture.makeBackupSnapshot(
            in: root,
            key: key,
            includeClipboardRecord: false
        )
        try replaceManifestWithLegacyVersion(at: snapshotURL)

        XCTAssertThrowsError(try MacClippyBackup.validate(at: snapshotURL, deviceKey: key)) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .keyCompatibilityUnproven)
        }
    }

    func testLegacyBackupAuthenticatesExistingEncryptedPayloads() throws {
        let root = try BackupValidationFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = BackupValidationFixture.testKey()
        let snapshotURL = try BackupValidationFixture.makeBackupSnapshot(in: root, key: key)
        try replaceManifestWithLegacyVersion(at: snapshotURL)

        let validation = try MacClippyBackup.validate(at: snapshotURL, deviceKey: key)
        XCTAssertTrue(validation.keyCompatible)
        XCTAssertTrue(MacClippyBackupSettingsPolicy.canRestore(validation))
        let wrongKey = SymmetricKey(data: Data(repeating: 9, count: 32))
        XCTAssertThrowsError(try MacClippyBackup.validate(at: snapshotURL, deviceKey: wrongKey)) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .keyMismatch)
        }
    }

    func testCurrentManifestAcceptsMixedCurrentAndLegacyRecordFormats() throws {
        let root = try BackupValidationFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = BackupValidationFixture.testKey()
        let clipboardDatabase = try MacClippyDatabase(inMemory: true)
        let clipboard = try ClipboardStore(database: clipboardDatabase, deviceKey: key)
        let legacy = try clipboard.append(.text("legacy body"))
        let current = try clipboard.append(.text("current body"))
        let legacyEnvelope = try MacClippyCipher.seal(
            JSONEncoder().encode(ClipboardRecord.text("legacy body")),
            with: key
        )
        try clipboardDatabase.queue.write { connection in
            try connection.execute(
                sql: """
                    UPDATE clipboard_records
                    SET envelope = ?, representation_refs_auth = NULL, blob_references_verified = 0
                    WHERE id = ?
                    """,
                arguments: [legacyEnvelope.combined, legacy.id.rawValue]
            )
        }
        let searchDatabase = try MacClippyDatabase(inMemory: true)
        _ = try SearchStore(database: searchDatabase)
        let pinboardDatabase = try MacClippyDatabase(inMemory: true)
        _ = try PinboardStore(database: pinboardDatabase, deviceKey: key)
        let snippetDatabase = try MacClippyDatabase(inMemory: true)
        _ = try SnippetStore(database: snippetDatabase, deviceKey: key)
        let blobsURL = root.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobsURL, withIntermediateDirectories: true)
        let snapshotURL = root.appendingPathComponent("mixed-snapshot", isDirectory: true)

        _ = try MacClippyBackup.create(
            sources: [
                MacClippyBackupSource(name: "clipboard", database: clipboardDatabase),
                MacClippyBackupSource(name: "search", database: searchDatabase),
                MacClippyBackupSource(name: "pinboards", database: pinboardDatabase),
                MacClippyBackupSource(name: "snippets", database: snippetDatabase)
            ],
            blobsURL: blobsURL,
            deviceKey: key,
            at: snapshotURL
        )
        let validation = try MacClippyBackup.validate(at: snapshotURL, deviceKey: key)

        XCTAssertTrue(validation.keyCompatible)
        XCTAssertEqual(validation.databaseRowCounts["clipboard"], 2)
        XCTAssertEqual(try clipboard.body(for: current.id), .text("current body"))
    }

    func testInstallerRejectsCurrentEnvelopeRosterAndVersionFailuresAfterManifestRehash() throws {
        let root = try BackupValidationFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = BackupValidationFixture.testKey()
        for (name, mutate) in installerRejectionCases() {
            try assertInstallerRejects(name: name, root: root, key: key, mutate: mutate)
        }
    }

    private func installerRejectionCases() -> [(String, ClipboardSnapshotMutation)] {
        [
            ("missing-roster", { database, recordID, _ in
                try database.write { connection in
                    try connection.execute(
                        sql: "UPDATE clipboard_records SET representation_refs_auth = NULL WHERE id = ?",
                        arguments: [recordID]
                    )
                }
            }),
            ("corrupt-roster", { database, recordID, _ in
                try database.write { connection in
                    try connection.execute(
                        sql: "UPDATE clipboard_records SET representation_refs_auth = ? WHERE id = ?",
                        arguments: [Data([0x00, 0xFF]), recordID]
                    )
                }
            }),
            ("unsupported-envelope-version", { database, recordID, key in
                let unsupported = MacClippyStoredClipboardRecordEnvelope(
                    recordFormatVersion: 99,
                    record: .text("authenticated unsupported envelope")
                )
                let encrypted = try MacClippyCipher.seal(JSONEncoder().encode(unsupported), with: key)
                try database.write { connection in
                    try connection.execute(
                        sql: "UPDATE clipboard_records SET envelope = ? WHERE id = ?",
                        arguments: [encrypted.combined, recordID]
                    )
                }
            })
        ]
    }

    private func assertInstallerRejects(
        name: String,
        root: URL,
        key: SymmetricKey,
        mutate: ClipboardSnapshotMutation
    ) throws {
        let caseRoot = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: caseRoot, withIntermediateDirectories: true)
        let snapshotURL = try BackupValidationFixture.makeBackupSnapshot(in: caseRoot, key: key)
        try mutateClipboardSnapshot(at: snapshotURL, key: key, mutate: mutate)
        let bytesBeforeValidation = try snapshotBytes(at: snapshotURL)
        let liveRoot = caseRoot.appendingPathComponent("live", isDirectory: true)
        let sentinel = liveRoot.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        try Data("old live root".utf8).write(to: sentinel)

        XCTAssertThrowsError(try MacClippyBackup.validate(at: snapshotURL, deviceKey: key), name) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .checksumMismatch("clipboard.sqlite"), name)
        }
        XCTAssertThrowsError(try MacClippyBackup.installIntoLiveRoot(
            from: snapshotURL,
            liveRootURL: liveRoot,
            deviceKey: key
        ), name)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("old live root".utf8), name)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: liveRoot.appendingPathComponent(MacClippyBackup.restoreJournalFileName).path
        ), name)
        XCTAssertEqual(try snapshotBytes(at: snapshotURL), bytesBeforeValidation, name)
    }

    private func mutateClipboardSnapshot(
        at snapshotURL: URL,
        key: SymmetricKey,
        mutate: ClipboardSnapshotMutation
    ) throws {
        let databaseURL = snapshotURL.appendingPathComponent("clipboard.sqlite")
        let database = try DatabaseQueue(path: databaseURL.path)
        let recordID = try XCTUnwrap(try database.read { connection in
            try String.fetchOne(connection, sql: "SELECT id FROM clipboard_records LIMIT 1")
        })
        try mutate(database, recordID, key)
        try database.close()
        try MacClippyBackup.normalize(databaseURL)

        let manifestURL = snapshotURL.appendingPathComponent(MacClippyBackup.manifestFileName)
        let manifest = try JSONDecoder().decode(MacClippyBackupManifest.self, from: Data(contentsOf: manifestURL))
        let sqliteData = try Data(contentsOf: databaseURL)
        let files = manifest.files.map { entry in
            entry.relativePath == "clipboard.sqlite"
                ? MacClippyBackupManifest.FileEntry(
                    relativePath: entry.relativePath,
                    byteCount: Int64(sqliteData.count),
                    sha256: Self.sha256(sqliteData)
                )
                : entry
        }
        let updated = MacClippyBackupManifest(
            formatVersion: manifest.formatVersion,
            createdAt: manifest.createdAt,
            databaseNames: manifest.databaseNames,
            files: files,
            keyCheck: manifest.keyCheck
        )
        try JSONEncoder().encode(updated).write(to: manifestURL, options: .atomic)
    }

    private func snapshotBytes(at snapshotURL: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: snapshotURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { throw CocoaError(.fileReadUnknown) }
        var bytes: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let path = String(url.path.dropFirst(snapshotURL.path.count + 1))
            bytes[path] = try Data(contentsOf: url)
        }
        return bytes
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func replaceManifestWithLegacyVersion(at snapshotURL: URL) throws {
        let manifestURL = snapshotURL.appendingPathComponent(MacClippyBackup.manifestFileName)
        let current = try JSONDecoder().decode(MacClippyBackupManifest.self, from: Data(contentsOf: manifestURL))
        let legacy = MacClippyBackupManifest(
            formatVersion: 1,
            createdAt: current.createdAt,
            databaseNames: current.databaseNames,
            files: current.files
        )
        try JSONEncoder().encode(legacy).write(to: manifestURL, options: .atomic)
    }
}
