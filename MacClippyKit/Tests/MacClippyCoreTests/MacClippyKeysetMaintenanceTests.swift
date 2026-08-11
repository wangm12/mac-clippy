import CryptoKit
import Foundation
import XCTest

import MacClippyCore

final class MacClippyKeysetMaintenanceTests: XCTestCase {
    func testRepresentationBlobKeysetCursorIncludesRowsInsertedAfterFirstPage() throws {
        let store = try clipboardStore()
        for index in 0..<256 {
            _ = try store.append(
                .text("record-\(index)"),
                representations: [
                    MacClippyClipboardRepresentation(
                        uti: "public.data",
                        payloadBytes: nil,
                        blobID: String(format: "blob-%04d", index),
                        payloadState: .spilled
                    )
                ]
            )
        }

        var shouldContinueCallCount = 0
        var scannedIDs: [String] = []
        try store.forEachRepresentationBlobID(
            shouldContinue: {
                shouldContinueCallCount += 1
                if shouldContinueCallCount == 2 {
                    // Simulate a capture committing while reconciliation is
                    // between bounded pages. The new key is after the first
                    // page cursor and must be visited without skipping rows.
                    _ = try? store.append(
                        .text("late record"),
                        representations: [
                            MacClippyClipboardRepresentation(
                                uti: "public.data",
                                payloadBytes: nil,
                                blobID: "blob-9999",
                                payloadState: .spilled
                            )
                        ]
                    )
                }
                return true
            },
            { blobID in
                scannedIDs.append(blobID)
            }
        )

        XCTAssertEqual(scannedIDs.count, 257)
        XCTAssertEqual(Set(scannedIDs).count, 257)
        XCTAssertTrue(scannedIDs.contains("blob-0000"))
        XCTAssertTrue(scannedIDs.contains("blob-0255"))
        XCTAssertTrue(scannedIDs.contains("blob-9999"))
    }

    private func clipboardStore() throws -> ClipboardStore {
        try ClipboardStore(
            database: MacClippyDatabase(inMemory: true),
            deviceKey: SymmetricKey(data: Data(repeating: 9, count: 32)),
            deviceID: try XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        )
    }
}
