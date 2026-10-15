import CryptoKit
import Foundation
import GRDB
import XCTest

@testable import MacClippyCore

final class MacClippyLegacyRosterMaintenanceTests: XCTestCase {
    func testSchema010And011V1RostersMigrateAndRetentionDeletesAfterExactPlayback() throws {
        var fixtures: [Fixture] = []
        defer { fixtures.forEach(cleanup) }

        for schema in HistoricalSchema.allCases {
            let fixture = try makeHistoricalFixture(schema: schema)
            fixtures.append(fixture)

            XCTAssertEqual(fixture.sourceMigrations.last, schema.migrationIdentifier)
            XCTAssertEqual(
                try appliedMigrations(in: fixture.database).last,
                "013-clipboard-records-revision-and-scope-index"
            )
            XCTAssertTrue(try fixture.database.queue.read { connection in
                try Row.fetchAll(connection, sql: "PRAGMA table_info(clipboard_representations)").contains {
                    let name: String = $0["name"]
                    return name == "item_index"
                }
            })

            let snapshot = try fixture.store.playbackSnapshot(for: fixture.recordID)
            XCTAssertEqual(snapshot.record, .text(fixture.text))
            XCTAssertEqual(snapshot.representations.map(\.itemIndex), [0])
            XCTAssertEqual(snapshot.representations.map(\.payloadBytes), [Data(fixture.text.utf8)])

            let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
            try search.upsert(id: fixture.recordID, text: fixture.text)
            let blobs = try BlobStore(rootURL: fixture.root.appendingPathComponent("blobs"), key: fixture.key)
            try RetentionPolicy(maxItems: 0).enforce(
                store: fixture.store,
                blobs: blobs,
                search: search
            )

            XCTAssertEqual(try fixture.store.databaseRowCount(), 0)
            XCTAssertTrue(try search.search(query: fixture.text, limit: 10).isEmpty)
        }
    }

    func testSchema010And011V1RostersReauthenticateAfterMarkerInvalidationDuringReconciliation() throws {
        var fixtures: [Fixture] = []
        defer { fixtures.forEach(cleanup) }

        for schema in HistoricalSchema.allCases {
            let fixture = try makeHistoricalFixture(schema: schema)
            fixtures.append(fixture)

            try fixture.database.queue.write { connection in
                try connection.execute(
                    sql: "UPDATE clipboard_records SET content_kind = content_kind WHERE id = ?",
                    arguments: [fixture.recordID.rawValue]
                )
            }
            XCTAssertEqual(try verifiedMarker(for: fixture.recordID, in: fixture.database), 0)

            let search = try SearchStore(database: MacClippyDatabase(inMemory: true))
            let blobs = try BlobStore(rootURL: fixture.root.appendingPathComponent("blobs"), key: fixture.key)
            let result = try MacClippyReconciliation.detect(store: fixture.store, search: search, blobs: blobs)

            XCTAssertEqual(result.orphanBlobCount, 0)
            XCTAssertEqual(result.missingBlobCount, 0)
            XCTAssertEqual(try verifiedMarker(for: fixture.recordID, in: fixture.database), 1)
            XCTAssertEqual(try fixture.store.playbackSnapshot(for: fixture.recordID).record, .text(fixture.text))
        }
    }

    func testSchema010And011V1RostersStillRejectWrongKeyTamperingAndReferenceMismatch() throws {
        var fixtures: [Fixture] = []
        defer { fixtures.forEach(cleanup) }

        for schema in HistoricalSchema.allCases {
            let fixture = try makeHistoricalFixture(schema: schema)
            fixtures.append(fixture)

            try invalidateReferenceMarker(for: fixture.recordID, in: fixture.database)
            let wrongKeyStore = try ClipboardStore(
                database: fixture.database,
                deviceKey: randomKey()
            )
            XCTAssertThrowsError(try wrongKeyStore.authenticateOwnedBlobReferenceIndex())
            XCTAssertEqual(try verifiedMarker(for: fixture.recordID, in: fixture.database), 0)

            let originalRoster = try fixture.database.queue.read { connection in
                try Data.fetchOne(
                    connection,
                    sql: "SELECT representation_refs_auth FROM clipboard_records WHERE id = ?",
                    arguments: [fixture.recordID.rawValue]
                )
            }
            var tamperedRoster = try XCTUnwrap(originalRoster)
            tamperedRoster[tamperedRoster.startIndex] ^= 0x01
            try fixture.database.queue.write { connection in
                try connection.execute(
                    sql: "UPDATE clipboard_records SET representation_refs_auth = ? WHERE id = ?",
                    arguments: [tamperedRoster, fixture.recordID.rawValue]
                )
            }
            XCTAssertThrowsError(try fixture.store.authenticateOwnedBlobReferenceIndex())
            XCTAssertEqual(try verifiedMarker(for: fixture.recordID, in: fixture.database), 0)

            let validRoster = try XCTUnwrap(originalRoster)
            let mismatchedPayload = try MacClippyCipher.seal(Data("different payload".utf8), with: fixture.key).combined
            try fixture.database.queue.write { connection in
                try connection.execute(
                    sql: "UPDATE clipboard_records SET representation_refs_auth = ? WHERE id = ?",
                    arguments: [validRoster, fixture.recordID.rawValue]
                )
                try connection.execute(
                    sql: "UPDATE clipboard_representations SET payload = ? WHERE record_id = ?",
                    arguments: [mismatchedPayload, fixture.recordID.rawValue]
                )
            }
            XCTAssertThrowsError(try fixture.store.authenticateOwnedBlobReferenceIndex()) { error in
                XCTAssertEqual(error as? MacClippyStoreError, .invalidStoredRecord)
            }
            XCTAssertEqual(try verifiedMarker(for: fixture.recordID, in: fixture.database), 0)
        }
    }
}

private extension MacClippyLegacyRosterMaintenanceTests {
    enum HistoricalSchema: CaseIterable {
        case schema010
        case schema011

        var migrationCount: Int {
            switch self {
            case .schema010: 10
            case .schema011: 11
            }
        }

        var migrationIdentifier: String {
            switch self {
            case .schema010: "010-authenticated-representation-roster"
            case .schema011: "011-content-kind-reference-invalidation"
            }
        }
    }

    struct Fixture {
        let root: URL
        let database: MacClippyDatabase
        let store: ClipboardStore
        let key: SymmetricKey
        let recordID: RecordID
        let text: String
        let sourceMigrations: [String]
    }

    struct HistoricalEnvelope: Encodable {
        let recordFormatVersion = 1
        let record: ClipboardRecord
    }

    struct HistoricalPayloads {
        let representation: Data
        let record: Data
        let roster: Data
    }

    func makeHistoricalFixture(schema: HistoricalSchema) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippySchemaRoster-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let key = randomKey()
        let databaseURL = root.appendingPathComponent("clipboard.sqlite")
        let recordID = RecordID.generate()
        let text = "schema \(schema.migrationIdentifier.prefix(3)) authenticated v1 roster"
        do {
            let sourceMigrations = try createHistoricalDatabase(
                at: databaseURL,
                schema: schema,
                key: key,
                recordID: recordID,
                text: text
            )
            // Reopening with the production migration list executes every real
            // remaining migration, including 011 when the source is schema 010
            // and migration 012 for both historical starting points.
            let database = try MacClippyDatabase(url: databaseURL, migrations: ClipboardStore.migrations)
            let store = try ClipboardStore(database: database, deviceKey: key)
            return Fixture(
                root: root,
                database: database,
                store: store,
                key: key,
                recordID: recordID,
                text: text,
                sourceMigrations: sourceMigrations
            )
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func createHistoricalDatabase(
        at url: URL,
        schema: HistoricalSchema,
        key: SymmetricKey,
        recordID: RecordID,
        text: String
    ) throws -> [String] {
        let database = try MacClippyDatabase(
            url: url,
            migrations: Array(ClipboardStore.migrations.prefix(schema.migrationCount))
        )
        defer { try? database.queue.close() }
        let payloads = try historicalV1Payloads(key: key, recordID: recordID, text: text)
        try insertHistoricalRecord(payloads, on: database, recordID: recordID, text: text)
        return try appliedMigrations(in: database)
    }

    func historicalV1Payloads(
        key: SymmetricKey,
        recordID: RecordID,
        text: String
    ) throws -> HistoricalPayloads {
        let representation = try MacClippyCipher.seal(Data(text.utf8), with: key).combined
        let record = try MacClippyCipher.seal(
            JSONEncoder().encode(HistoricalEnvelope(record: .text(text))),
            with: key
        ).combined
        let roster = MacClippyRepresentationRoster(
            version: 1,
            recordID: recordID.rawValue,
            representations: [
                MacClippyRepresentationRosterEntry(
                    itemIndex: 0,
                    sortOrder: 0,
                    uti: "public.utf8-plain-text",
                    state: "present",
                    blobID: nil,
                    payloadDigest: Data(SHA256.hash(data: representation))
                )
            ]
        )
        let authenticatedRoster = try MacClippyRepresentationRosterCodec.seal(roster, key: key)
        return HistoricalPayloads(representation: representation, record: record, roster: authenticatedRoster)
    }

    func insertHistoricalRecord(
        _ payloads: HistoricalPayloads,
        on database: MacClippyDatabase,
        recordID: RecordID,
        text: String
    ) throws {
        try database.queue.write { connection in
            try connection.execute(
                sql: """
                    INSERT INTO clipboard_records(
                        id, created, modified, device_id, lamport, kind, content_kind,
                        preview, envelope, representation_refs_auth, blob_references_verified
                    ) VALUES(?, 1, 1, ?, 1, 'clipboardItem', 'text', ?, ?, ?, 0)
                    """,
                arguments: [recordID.rawValue, DeviceID.generate().rawValue, text, payloads.record, payloads.roster]
            )
            try connection.execute(
                sql: """
                    INSERT INTO clipboard_representations(
                        record_id, sort_order, uti, payload, payload_state
                    ) VALUES(?, 0, 'public.utf8-plain-text', ?, 'present')
                    """,
                arguments: [recordID.rawValue, payloads.representation]
            )
            try connection.execute(
                sql: "UPDATE clipboard_records SET blob_references_verified = 1 WHERE id = ?",
                arguments: [recordID.rawValue]
            )
        }
    }

    func invalidateReferenceMarker(for id: RecordID, in database: MacClippyDatabase) throws {
        try database.queue.write { connection in
            try connection.execute(
                sql: "UPDATE clipboard_records SET content_kind = content_kind WHERE id = ?",
                arguments: [id.rawValue]
            )
        }
    }

    func verifiedMarker(for id: RecordID, in database: MacClippyDatabase) throws -> Int {
        try database.queue.read { connection in
            try Int.fetchOne(
                connection,
                sql: "SELECT blob_references_verified FROM clipboard_records WHERE id = ?",
                arguments: [id.rawValue]
            ) ?? -1
        }
    }

    func appliedMigrations(in database: MacClippyDatabase) throws -> [String] {
        try database.queue.read { connection in
            try String.fetchAll(connection, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
        }
    }

    func randomKey() -> SymmetricKey {
        SymmetricKey(data: Data((0..<32).map { _ in UInt8.random(in: 0...UInt8.max) }))
    }

    func cleanup(_ fixture: Fixture) {
        try? fixture.database.queue.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }
}
