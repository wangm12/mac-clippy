import CryptoKit
import Foundation
import GRDB
import XCTest

@testable import MacClippyCore

final class MacClippyBackupArchiveTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    func testArchiveRoundTripAndPassphraseValidation() throws {
        let archiveURL = rootURL.appendingPathComponent("multi-chunk.macclippybackup")
        let manifest = try createMultiChunkTestArchive(to: archiveURL)
        XCTAssertEqual(manifest.databaseNames.count, 4)

        let handle = try FileHandle(forReadingFrom: archiveURL)
        let prefix = try handle.read(upToCount: MacClippyBackupArchive.magic.count)
        try handle.close()
        XCTAssertEqual(prefix, MacClippyBackupArchive.magic)

        XCTAssertThrowsError(try MacClippyBackup.validateArchive(at: archiveURL, passphrase: "")) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .passphraseRequired)
        }
        XCTAssertThrowsError(try MacClippyBackup.validateArchive(at: archiveURL, passphrase: "wrong")) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .invalidPassphrase)
        }

        let validation = try MacClippyBackup.validateArchive(
            at: archiveURL,
            passphrase: "correct-horse-battery-staple"
        )
        XCTAssertTrue(MacClippyBackupSettingsPolicy.canRestore(validation))
    }

    func testArchiveDetectsTamperingAndTruncation() throws {
        let archiveURL = rootURL.appendingPathComponent("multi-chunk.macclippybackup")
        _ = try createMultiChunkTestArchive(to: archiveURL)

        var archiveBytes = try Data(contentsOf: archiveURL)
        let tamperedURL = rootURL.appendingPathComponent("tampered.macclippybackup")
        archiveBytes[archiveBytes.count - 5] ^= 0xFF
        try archiveBytes.write(to: tamperedURL)
        XCTAssertThrowsError(
            try MacClippyBackup.validateArchive(at: tamperedURL, passphrase: "correct-horse-battery-staple")
        ) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .corruptedArchive)
        }

        let truncatedURL = rootURL.appendingPathComponent("truncated.macclippybackup")
        try Data(contentsOf: archiveURL).dropLast(1).write(to: truncatedURL)
        XCTAssertThrowsError(
            try MacClippyBackup.validateArchive(at: truncatedURL, passphrase: "correct-horse-battery-staple")
        ) { error in
            XCTAssertEqual(error as? MacClippyBackupError, .corruptedArchive)
        }
    }

    func testEntryDecoderRejectsPathTraversalAndBackslashes() throws {
        for badPath in ["../outside.txt", "/etc/passwd", "dir\\escape.txt"] {
            var decoder = MacClippyBackupArchiveEntryDecoder(
                destinationDirectory: rootURL.appendingPathComponent("unpack", isDirectory: true),
                fileManager: .default
            )
            let pathData = Data(badPath.utf8)
            var payload = MacClippyBackupArchive.bigEndianBytes(UInt16(pathData.count))
            payload.append(pathData)
            XCTAssertThrowsError(try decoder.consume(payload)) { error in
                XCTAssertEqual(error as? MacClippyBackupError, .corruptedArchive)
            }
        }
    }

    func testCrossMacRestoreReKeysStoresRepresentationsAndBlobs() throws {
        let sourceKey = SymmetricKey(size: .bits256)
        let targetKey = SymmetricKey(size: .bits256)
        let sourceRoot = rootURL.appendingPathComponent("mac-a", isDirectory: true)
        let targetRoot = rootURL.appendingPathComponent("mac-b", isDirectory: true)
        let archiveURL = rootURL.appendingPathComponent("transfer.macclippybackup")

        let seeded = try populateAndArchiveCrossMacSource(at: sourceRoot, key: sourceKey, archiveURL: archiveURL)

        let dstSeed = try makeFixture(at: targetRoot, key: targetKey)
        let targetKeySource = dstSeed.clipboard.backupKeySource
        dstSeed.close()

        _ = try MacClippyBackup.installArchiveIntoLiveRoot(
            from: archiveURL,
            passphrase: "migration-passphrase",
            liveRootURL: targetRoot,
            targetKeySource: targetKeySource
        )
        try MacClippyBackup.finalizePendingRestore(at: targetRoot)

        let reopened = try makeFixture(at: targetRoot, key: targetKey)
        defer { reopened.close() }
        let textPlayback = try reopened.clipboard.playbackSnapshot(for: seeded.textID)
        XCTAssertEqual(textPlayback.record, .text("Hello cross-Mac"))
        XCTAssertEqual(textPlayback.representations.first?.payloadBytes, Data("Hello cross-Mac".utf8))

        let imgPlayback = try reopened.clipboard.playbackSnapshot(for: seeded.imageID)
        XCTAssertEqual(
            imgPlayback.record,
            .encryptedImage(blobID: seeded.imageBlobID, width: 100, height: 100)
        )
        XCTAssertEqual(try reopened.blobStore.read(id: seeded.imageBlobID), Data("fake-image-bytes".utf8))
        XCTAssertEqual(try reopened.pinboards.listStrict().map(\.name), ["Saved Board"])
        XCTAssertEqual(try reopened.snippets.listStrict().map(\.name), ["Sig"])
    }
}

private struct CrossMacSeedIDs {
    let textID: RecordID
    let imageID: RecordID
    let imageBlobID: String
}

private struct BackupFixture {
    let databases: [MacClippyDatabase]
    let clipboard: ClipboardStore
    let search: SearchStore
    let pinboards: PinboardStore
    let snippets: SnippetStore
    let blobStore: BlobStore

    var sources: [MacClippyBackupSource] {
        [
            MacClippyBackupSource(name: "clipboard", database: databases[0]),
            MacClippyBackupSource(name: "search", database: databases[1]),
            MacClippyBackupSource(name: "pinboards", database: databases[2]),
            MacClippyBackupSource(name: "snippets", database: databases[3])
        ]
    }

    func close() {
        for database in databases {
            try? database.queue.close()
        }
    }
}

private extension MacClippyBackupArchiveTests {
    func createMultiChunkTestArchive(to archiveURL: URL) throws -> MacClippyBackupManifest {
        let sourceKey = SymmetricKey(size: .bits256)
        let sourceRoot = rootURL.appendingPathComponent("source", isDirectory: true)
        let fixture = try makeFixture(at: sourceRoot, key: sourceKey)
        defer { fixture.close() }

        let largePayload = Data(repeating: 0xAB, count: 5 * 1024 * 1024)
        let largeBlobID = try fixture.blobStore.write(largePayload)
        let rep = MacClippyClipboardRepresentation(
            itemIndex: 0,
            uti: "public.png",
            payloadBytes: nil,
            blobID: largeBlobID,
            payloadState: .spilled
        )
        _ = try fixture.clipboard.append(
            .encryptedImage(blobID: largeBlobID, width: 800, height: 600),
            representations: [rep]
        )
        let options = MacClippyBackupArchiveOptions(
            passphrase: "correct-horse-battery-staple",
            pbkdf2Iterations: MacClippyBackupArchive.minimumPBKDF2Iterations
        )
        return try MacClippyBackup.createArchive(
            sources: fixture.sources,
            blobsURL: sourceRoot.appendingPathComponent("blobs", isDirectory: true),
            keySource: fixture.clipboard.backupKeySource,
            to: archiveURL,
            options: options
        )
    }

    func populateAndArchiveCrossMacSource(
        at sourceRoot: URL,
        key: SymmetricKey,
        archiveURL: URL
    ) throws -> CrossMacSeedIDs {
        let src = try makeFixture(at: sourceRoot, key: key)
        defer { src.close() }
        let inlineRep = MacClippyClipboardRepresentation(
            itemIndex: 0,
            uti: "public.utf8-plain-text",
            payloadBytes: Data("Hello cross-Mac".utf8),
            blobID: nil,
            payloadState: .present
        )
        let textMeta = try src.clipboard.append(.text("Hello cross-Mac"), representations: [inlineRep])
        let imgBlobID = try src.blobStore.write(Data("fake-image-bytes".utf8))
        let imgRep = MacClippyClipboardRepresentation(
            itemIndex: 0,
            uti: "public.png",
            payloadBytes: nil,
            blobID: imgBlobID,
            payloadState: .spilled
        )
        let imgMeta = try src.clipboard.append(
            .encryptedImage(blobID: imgBlobID, width: 100, height: 100),
            representations: [imgRep]
        )
        let board = try src.pinboards.create(name: "Saved Board")
        try src.pinboards.addItem(textMeta.id, to: board.id)
        _ = try src.snippets.create(name: "Sig", body: "Best regards", trigger: ":sig")

        let options = MacClippyBackupArchiveOptions(
            passphrase: "migration-passphrase",
            pbkdf2Iterations: MacClippyBackupArchive.minimumPBKDF2Iterations
        )
        try MacClippyBackup.createArchive(
            sources: src.sources,
            blobsURL: sourceRoot.appendingPathComponent("blobs", isDirectory: true),
            keySource: src.clipboard.backupKeySource,
            to: archiveURL,
            options: options
        )
        return CrossMacSeedIDs(textID: textMeta.id, imageID: imgMeta.id, imageBlobID: imgBlobID)
    }

    func makeFixture(at root: URL, key: SymmetricKey) throws -> BackupFixture {
        let dbDir = root.appendingPathComponent("databases", isDirectory: true)
        let blobDir = root.appendingPathComponent("blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let clipboardDB = try MacClippyDatabase(url: dbDir.appendingPathComponent("clipboard.sqlite"))
        let searchDB = try MacClippyDatabase(url: dbDir.appendingPathComponent("search.sqlite"))
        let pinboardDB = try MacClippyDatabase(url: dbDir.appendingPathComponent("pinboards.sqlite"))
        let snippetDB = try MacClippyDatabase(url: dbDir.appendingPathComponent("snippets.sqlite"))
        return BackupFixture(
            databases: [clipboardDB, searchDB, pinboardDB, snippetDB],
            clipboard: try ClipboardStore(database: clipboardDB, deviceKey: key),
            search: try SearchStore(database: searchDB),
            pinboards: try PinboardStore(database: pinboardDB, deviceKey: key),
            snippets: try SnippetStore(database: snippetDB, deviceKey: key),
            blobStore: try BlobStore(rootURL: blobDir, key: key)
        )
    }
}
