import CryptoKit
import Foundation
import XCTest

import MacClippyCore

/// Opt-in scale checks for the release-readiness matrix. They are not part of
/// the default package suite because they intentionally create a large,
/// disposable fixture and exercise the filesystem for several seconds.
@MainActor
final class MacClippyScaleTests: XCTestCase {
    func testOneHundredThousandRecordsRemainSearchableAndPaged() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACCLIPPY_RUN_SCALE_TESTS"] == "1",
            "Set MACCLIPPY_RUN_SCALE_TESTS=1 to run the 100,000-record fixture."
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyScale-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let clipboardDatabase = try MacClippyDatabase(
            url: root.appendingPathComponent("clipboard.sqlite")
        )
        let searchDatabase = try MacClippyDatabase(
            url: root.appendingPathComponent("search.sqlite")
        )
        let clipboard = try ClipboardStore(database: clipboardDatabase, deviceKey: key)
        let search = try SearchStore(database: searchDatabase)

        let count = 100_000
        let insertionStart = Date()
        for index in 0..<count {
            let marker = "scalemark\(index)"
            let meta = try clipboard.append(
                .text("scale fixture \(marker)"),
                now: Date(timeIntervalSince1970: 1_000_000 + Double(index))
            )
            try search.insert(id: meta.id, text: marker)
        }
        let insertionDuration = Date().timeIntervalSince(insertionStart)

        let searchStart = Date()
        let hits = try search.search(query: "scalemark99999", limit: 20)
        let searchDuration = Date().timeIntervalSince(searchStart)

        let pageStart = Date()
        let page = try clipboard.list(limit: 50)
        let pageDuration = Date().timeIntervalSince(pageStart)

        XCTAssertEqual(try clipboard.databaseRowCount(), Int64(count))
        XCTAssertEqual(try search.databaseRowCount(), Int64(count))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(page.count, 50)
        XCTAssertLessThan(insertionDuration, 180, "100,000-record insertion exceeded the scale budget")
        XCTAssertLessThan(searchDuration, 3, "FTS search exceeded the scale budget")
        XCTAssertLessThan(pageDuration, 3, "metadata page read exceeded the scale budget")

        XCTContext.runActivity(named: "MacClippy 100k scale timings") { activity in
            activity.add(XCTAttachment(string: "records=\(count)"))
            activity.add(XCTAttachment(string: "insert_seconds=\(insertionDuration)"))
            activity.add(XCTAttachment(string: "search_seconds=\(searchDuration)"))
            activity.add(XCTAttachment(string: "page_seconds=\(pageDuration)"))
        }

        try clipboardDatabase.queue.close()
        try searchDatabase.queue.close()
    }

    func testTwentyMegabyteRepresentationSpillsAndDeletesCleanly() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MACCLIPPY_RUN_SCALE_TESTS"] == "1",
            "Set MACCLIPPY_RUN_SCALE_TESTS=1 to run the large-payload fixture."
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyLargePayload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = SymmetricKey(data: Data(repeating: 8, count: 32))
        let database = try MacClippyDatabase(url: root.appendingPathComponent("clipboard.sqlite"))
        let clipboard = try ClipboardStore(database: database, deviceKey: key)
        let blobs = try BlobStore(rootURL: root.appendingPathComponent("blobs"), key: key)
        let payload = Data(repeating: 0xA5, count: 20 * 1_024 * 1_024)

        let meta = try clipboard.append(
            .text("large payload fixture"),
            representations: [
                MacClippyClipboardRepresentation(uti: "public.data", payloadBytes: payload)
            ],
            spillPayload: { try blobs.write($0) },
            deleteSpilledPayload: { blobID in try? blobs.delete(id: blobID) }
        )

        let representation = try XCTUnwrap(try clipboard.representations(for: meta.id).first)
        let blobID = try XCTUnwrap(representation.blobID)
        XCTAssertEqual(representation.payloadState, .spilled)
        XCTAssertEqual(try blobs.read(id: blobID), payload)

        let journal = try XCTUnwrap(try clipboard.beginDeletion(ids: [meta.id]))
        try clipboard.delete(id: meta.id)
        let referenced = try clipboard.referencedBlobIDs()
        if !referenced.contains(blobID) {
            try blobs.delete(id: blobID)
        }
        try clipboard.completeDeletion(operationID: journal.operationID)

        XCTAssertFalse(try blobs.contains(id: blobID))
        XCTAssertEqual(try clipboard.databaseRowCount(), 0)
        try database.queue.close()
    }
}
