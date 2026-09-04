import CryptoKit
import GRDB
import XCTest

@testable import MacClippyCore

final class MacClippyStructuredSearchIndexTests: XCTestCase {
    func testRequiredIndexesCoverTypeAppAndHasOCR() {
        XCTAssertEqual(
            MacClippyStructuredSearchIndexPolicy.requiredIndexNames,
            [
                "idx_macclippy_records_content_kind",
                "idx_macclippy_records_source_app",
                "idx_macclippy_records_source_app_name",
                "idx_macclippy_records_has_ocr"
            ]
        )
    }

    func testClipboardStoreCreatesStructuredSearchIndexes() throws {
        let database = try MacClippyDatabase(inMemory: true)
        _ = try ClipboardStore(
            database: database,
            deviceKey: SymmetricKey(data: Data(repeating: 9, count: 32))
        )
        let names = try database.queue.read { connection in
            try String.fetchAll(
                connection,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'index'
                      AND name IN (?, ?, ?, ?)
                    ORDER BY name
                    """,
                arguments: [
                    "idx_macclippy_records_content_kind",
                    "idx_macclippy_records_has_ocr",
                    "idx_macclippy_records_source_app",
                    "idx_macclippy_records_source_app_name"
                ]
            )
        }
        XCTAssertEqual(
            names,
            MacClippyStructuredSearchIndexPolicy.requiredIndexNames.sorted()
        )
    }
}
