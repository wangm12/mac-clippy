import CryptoKit
import Foundation
import XCTest

import GRDB
import MacClippyCore

// P2a focused tests for ClipboardStore.setCustomLabel: trimmed persistence,
// blank clears, modified bump, recordNotFound, and meta reflection. The
// runtime-level search/index preservation is covered by the app test target
// (MacClippyLabelTests) because it needs the runtime's private search store.
final class MacClippyLabelCoreTests: XCTestCase {
    func testSetCustomLabelTrimsPersistsAndBumpsModified() throws {
        let store = try clipboardStore()
        let created = Date(timeIntervalSince1970: 1_000)
        let original = try store.append(.text("body text"), now: created)

        let editTime = Date(timeIntervalSince1970: 2_000)
        let meta = try store.setCustomLabel(id: original.id, label: "  My Label  ", now: editTime)

        XCTAssertEqual(meta.customLabel, "My Label")
        XCTAssertEqual(meta.id, original.id)
        // modified is bumped so ordering by modified DESC stays meaningful.
        XCTAssertEqual(meta.modified, editTime)

        // Persisted: a fresh read returns the trimmed label.
        let reloaded = try store.metas(for: [original.id]).first
        XCTAssertEqual(reloaded?.customLabel, "My Label")
    }

    func testSetCustomLabelBlankClearsTheStoredLabel() throws {
        let store = try clipboardStore()
        let original = try store.append(.text("body text"), now: Date(timeIntervalSince1970: 1_000))
        _ = try store.setCustomLabel(id: original.id, label: "kept", now: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(try store.metas(for: [original.id]).first?.customLabel, "kept")

        // A whitespace-only label normalizes to nil and clears the stored label.
        let cleared = try store.setCustomLabel(id: original.id, label: "   \n  ", now: Date(timeIntervalSince1970: 3_000))
        XCTAssertNil(cleared.customLabel)
        XCTAssertNil(try store.metas(for: [original.id]).first?.customLabel)

        // An explicit nil also clears.
        _ = try store.setCustomLabel(id: original.id, label: "again", now: Date(timeIntervalSince1970: 4_000))
        let clearedAgain = try store.setCustomLabel(id: original.id, label: nil, now: Date(timeIntervalSince1970: 5_000))
        XCTAssertNil(clearedAgain.customLabel)
    }

    func testSetCustomLabelThrowsRecordNotFoundForMissingID() throws {
        let store = try clipboardStore()
        let stale = RecordID.generate()
        XCTAssertThrowsError(try store.setCustomLabel(id: stale, label: "x")) { error in
            XCTAssertEqual(error as? MacClippyStoreError, .recordNotFound)
        }
    }

    func testSetCustomLabelDoesNotAlterBodyOrOCRText() throws {
        let store = try clipboardStore()
        let original = try store.append(.text("the body text"), now: Date(timeIntervalSince1970: 1_000))
        try store.setOCRText(id: original.id, text: "ocr words")

        _ = try store.setCustomLabel(id: original.id, label: "label", now: Date(timeIntervalSince1970: 2_000))

        // The label edit must not corrupt the body or OCR text; both are still
        // readable for the runtime's index rebuild.
        XCTAssertEqual(try store.body(for: original.id), .text("the body text"))
        XCTAssertEqual(try store.metas(for: [original.id]).first?.ocrText, "ocr words")
    }

    private func clipboardStore() throws -> ClipboardStore {
        try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: testKey(),
            deviceID: XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
    }

    private func testKey() -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 9, count: 32))
    }
}
