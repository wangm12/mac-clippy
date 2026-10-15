import CryptoKit
import Foundation
import XCTest

import MacClippyCore

final class MacClippyRepresentationPayloadTests: XCTestCase {
    func testAppendWithRepresentationsRoundTripsEveryUTI() throws {
        let store = try clipboardStore()
        let now = Date(timeIntervalSince1970: 12_000)
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("hello world".utf8)),
            MacClippyClipboardRepresentation(uti: "public.html", payloadBytes: Data("<b>hi</b>".utf8)),
            MacClippyClipboardRepresentation(uti: "public.rtf", payloadBytes: Data("{\\rtf1 rich}".utf8)),
            MacClippyClipboardRepresentation(uti: "public.tiff", payloadBytes: Data([0x49, 0x49, 0x2A, 0x00, 0x01])),
            MacClippyClipboardRepresentation(uti: "com.example.custom-uti", payloadBytes: Data("custom-payload".utf8))
        ]

        let meta = try store.append(
            .text("hello world"),
            representations: representations,
            sourceAppBundleID: "com.example.Editor",
            now: now
        )

        let stored = try store.representations(for: meta.id)
        XCTAssertEqual(stored.count, representations.count)
        XCTAssertEqual(stored.map(\.uti), representations.map(\.uti))
        for (expected, actual) in zip(representations, stored) {
            XCTAssertEqual(actual.payloadBytes, expected.payloadBytes)
            XCTAssertNil(actual.blobID)
        }
    }

    func testConcealedTransientAndCustomUTIsAreRetained() throws {
        let store = try clipboardStore()
        let representations = [
            MacClippyClipboardRepresentation(
                uti: "org.nspasteboard.ConcealedType",
                payloadBytes: Data("concealed".utf8)
            ),
            MacClippyClipboardRepresentation(
                uti: "org.nspasteboard.TransientType",
                payloadBytes: Data("transient".utf8)
            ),
            MacClippyClipboardRepresentation(
                uti: "org.nspasteboard.PasteboardType",
                payloadBytes: Data("managed".utf8)
            ),
            MacClippyClipboardRepresentation(uti: "com.unknown.nothing-uti", payloadBytes: Data([0x00, 0xFF])),
            MacClippyClipboardRepresentation(uti: "dyn.age50u2u", payloadBytes: Data("dynamic".utf8))
        ]

        let meta = try store.append(
            .text("concealed-transient-custom"),
            representations: representations,
            now: Date(timeIntervalSince1970: 1)
        )
        let stored = try store.representations(for: meta.id)

        XCTAssertEqual(Set(stored.map(\.uti)), Set(representations.map(\.uti)))
        for (expected, actual) in zip(representations, stored) {
            XCTAssertEqual(actual.payloadBytes, expected.payloadBytes)
        }
    }

    func testRecordIDsContainingUTIFindsRemoteClipboardMarker() throws {
        let store = try clipboardStore()
        let remote = try store.append(
            .text("from iphone"),
            representations: [
                MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("from iphone".utf8)),
                MacClippyClipboardRepresentation(
                    uti: CaptureExclusionRules.remoteClipboardPasteboardType,
                    payloadBytes: Data()
                )
            ]
        )
        let local = try store.append(
            .text("local"),
            representations: [
                MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("local".utf8))
            ]
        )

        XCTAssertEqual(
            try store.recordIDsContainingUTI(
                CaptureExclusionRules.remoteClipboardPasteboardType,
                in: [remote.id, local.id]
            ),
            [remote.id]
        )
        XCTAssertTrue(
            try store.recordIDsContainingUTI(
                CaptureExclusionRules.remoteClipboardPasteboardType,
                in: []
            ).isEmpty
        )
        XCTAssertTrue(
            try store.recordIDsContainingUTI(
                CaptureExclusionRules.remoteClipboardPasteboardType,
                in: [local.id]
            ).isEmpty
        )
    }

    func testAppendRetainsEmptyAndUnavailablePayloadsAsMarkers() throws {
        let store = try clipboardStore()
        let representations = [
            MacClippyClipboardRepresentation(uti: "public.html", payloadBytes: Data()),
            MacClippyClipboardRepresentation(uti: "com.empty", payloadBytes: Data()),
            MacClippyClipboardRepresentation(
                uti: "com.missing",
                payloadBytes: nil,
                blobID: nil,
                payloadState: .unavailable
            ),
            MacClippyClipboardRepresentation(uti: "public.utf8-plain-text", payloadBytes: Data("kept".utf8))
        ]

        let meta = try store.append(
            .text("kept"),
            representations: representations,
            now: Date(timeIntervalSince1970: 1)
        )
        let stored = try store.representations(for: meta.id)

        XCTAssertEqual(
            Set(stored.map(\.uti)),
            Set(["public.html", "com.empty", "com.missing", "public.utf8-plain-text"])
        )
        let byUTI = Dictionary(uniqueKeysWithValues: stored.map { ($0.uti, $0) })
        XCTAssertEqual(byUTI["public.html"]?.payloadBytes, Data())
        XCTAssertEqual(byUTI["public.html"]?.payloadState, .present)
        XCTAssertEqual(byUTI["com.empty"]?.payloadBytes, Data())
        XCTAssertEqual(byUTI["com.empty"]?.payloadState, .present)
        XCTAssertNil(byUTI["com.missing"]?.payloadBytes)
        XCTAssertNil(byUTI["com.missing"]?.blobID)
        XCTAssertEqual(byUTI["com.missing"]?.payloadState, .unavailable)
        XCTAssertEqual(byUTI["public.utf8-plain-text"]?.payloadBytes, Data("kept".utf8))
        XCTAssertEqual(byUTI["public.utf8-plain-text"]?.payloadState, .present)
    }

    private func clipboardStore() throws -> ClipboardStore {
        try ClipboardStore(database: MacClippyDatabase(inMemory: true), deviceKey: testKey())
    }

    private func testKey() -> SymmetricKey {
        SymmetricKey(data: Data(repeating: 9, count: 32))
    }
}
