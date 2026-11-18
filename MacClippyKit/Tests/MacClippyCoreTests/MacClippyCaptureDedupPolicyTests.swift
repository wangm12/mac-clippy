import XCTest

@testable import MacClippyCore

final class MacClippyCaptureDedupPolicyTests: XCTestCase {
    func testIdenticalPrimaryAndRepresentationsProduceTheSameHash() {
        let left = MacClippyCaptureDedupPolicy.contentHash(
            primary: .text("hello"),
            representations: [
                MacClippyCaptureDedupRepresentation(
                    uti: "public.utf8-plain-text",
                    payloadState: "present",
                    payloadBytes: Data("hello".utf8)
                )
            ]
        )
        let right = MacClippyCaptureDedupPolicy.contentHash(
            primary: .text("hello"),
            representations: [
                MacClippyCaptureDedupRepresentation(
                    uti: "public.utf8-plain-text",
                    payloadState: "present",
                    payloadBytes: Data("hello".utf8)
                )
            ]
        )
        XCTAssertEqual(left, right)
        XCTAssertFalse(left.isEmpty)
    }

    func testDifferentPrimaryPayloadsProduceDifferentHashes() {
        let hello = MacClippyCaptureDedupPolicy.contentHash(primary: .text("hello"), representations: [])
        let world = MacClippyCaptureDedupPolicy.contentHash(primary: .text("world"), representations: [])
        XCTAssertNotEqual(hello, world)
    }

    func testImageHashUsesBytesNotABlobIdentifier() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let first = MacClippyCaptureDedupPolicy.contentHash(
            primary: .image(png, width: 2, height: 2),
            representations: []
        )
        let second = MacClippyCaptureDedupPolicy.contentHash(
            primary: .image(png, width: 2, height: 2),
            representations: []
        )
        let different = MacClippyCaptureDedupPolicy.contentHash(
            primary: .image(Data([0x00]), width: 2, height: 2),
            representations: []
        )
        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, different)
    }

    func testRepresentationPayloadIsPartOfTheHash() {
        let plain = MacClippyCaptureDedupPolicy.contentHash(
            primary: .text("hello"),
            representations: [
                MacClippyCaptureDedupRepresentation(
                    uti: "public.utf8-plain-text",
                    payloadState: "present",
                    payloadBytes: Data("hello".utf8)
                )
            ]
        )
        let rich = MacClippyCaptureDedupPolicy.contentHash(
            primary: .text("hello"),
            representations: [
                MacClippyCaptureDedupRepresentation(
                    uti: "public.utf8-plain-text",
                    payloadState: "present",
                    payloadBytes: Data("hello".utf8)
                ),
                MacClippyCaptureDedupRepresentation(
                    uti: "public.rtf",
                    payloadState: "present",
                    payloadBytes: Data("rtf".utf8)
                )
            ]
        )
        XCTAssertNotEqual(plain, rich)
    }

    func testMultiItemHashBindsRepeatedUTIToItsNativeItem() {
        let first = MacClippyCaptureDedupPolicy.contentHash(
            primary: .text("copy"),
            representations: [
                MacClippyCaptureDedupRepresentation(
                    itemIndex: 0,
                    uti: "public.utf8-plain-text",
                    payloadState: "present",
                    payloadBytes: Data("one".utf8)
                ),
                MacClippyCaptureDedupRepresentation(
                    itemIndex: 1,
                    uti: "public.utf8-plain-text",
                    payloadState: "present",
                    payloadBytes: Data("two".utf8)
                )
            ]
        )
        let swapped = MacClippyCaptureDedupPolicy.contentHash(
            primary: .text("copy"),
            representations: [
                MacClippyCaptureDedupRepresentation(
                    itemIndex: 0,
                    uti: "public.utf8-plain-text",
                    payloadState: "present",
                    payloadBytes: Data("two".utf8)
                ),
                MacClippyCaptureDedupRepresentation(
                    itemIndex: 1,
                    uti: "public.utf8-plain-text",
                    payloadState: "present",
                    payloadBytes: Data("one".utf8)
                )
            ]
        )

        XCTAssertNotEqual(first, swapped)
    }

    func testHealthyDuplicateRowSkipsEnvelopeOpen() {
        let id = RecordID.generate().rawValue
        XCTAssertTrue(
            MacClippyCaptureDedupPolicy.canSkipEnvelopeOpen(
                recordID: id,
                contentKind: MacClippyContentKind.text.rawValue,
                preview: "hello",
                envelopeByteCount: MacClippyCaptureDedupPolicy.minimumSealedEnvelopeByteCount
            )
        )
    }

    func testGarbageOrIncompleteRowsStillRequireEnvelopeOpen() {
        let id = RecordID.generate().rawValue
        XCTAssertFalse(
            MacClippyCaptureDedupPolicy.canSkipEnvelopeOpen(
                recordID: id,
                contentKind: MacClippyContentKind.text.rawValue,
                preview: "hello",
                envelopeByteCount: 3
            )
        )
        XCTAssertFalse(
            MacClippyCaptureDedupPolicy.canSkipEnvelopeOpen(
                recordID: "not-a-record-id",
                contentKind: MacClippyContentKind.text.rawValue,
                preview: "hello",
                envelopeByteCount: 64
            )
        )
        XCTAssertFalse(
            MacClippyCaptureDedupPolicy.canSkipEnvelopeOpen(
                recordID: id,
                contentKind: nil,
                preview: "hello",
                envelopeByteCount: 64
            )
        )
        XCTAssertFalse(
            MacClippyCaptureDedupPolicy.canSkipEnvelopeOpen(
                recordID: id,
                contentKind: MacClippyContentKind.text.rawValue,
                preview: "",
                envelopeByteCount: 64
            )
        )
    }
}
