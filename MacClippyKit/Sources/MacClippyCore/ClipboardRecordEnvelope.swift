import Foundation

struct MacClippyStoredClipboardRecordEnvelope: Codable {
    let recordFormatVersion: Int
    let record: ClipboardRecord
}

struct MacClippyDecodedClipboardRecordEnvelope: Decodable {
    let record: ClipboardRecord
    let requiresRepresentationRoster: Bool

    private enum CodingKeys: String, CodingKey {
        case recordFormatVersion
        case record
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.recordFormatVersion) else {
            record = try ClipboardRecord(from: decoder)
            requiresRepresentationRoster = false
            return
        }
        let version = try container.decode(Int.self, forKey: .recordFormatVersion)
        guard version == MacClippyClipboardRecordEnvelopeCodec.currentRecordFormatVersion else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        record = try container.decode(ClipboardRecord.self, forKey: .record)
        requiresRepresentationRoster = true
    }
}

enum MacClippyClipboardRecordEnvelopeCodec {
    static let currentRecordFormatVersion = 1

    static func encode(_ record: ClipboardRecord, requiresRepresentationRoster: Bool = true) throws -> Data {
        if requiresRepresentationRoster {
            return try JSONEncoder().encode(
                MacClippyStoredClipboardRecordEnvelope(
                    recordFormatVersion: currentRecordFormatVersion,
                    record: record
                )
            )
        }
        return try JSONEncoder().encode(record)
    }

    static func decode(_ data: Data) throws -> MacClippyDecodedClipboardRecordEnvelope {
        try JSONDecoder().decode(MacClippyDecodedClipboardRecordEnvelope.self, from: data)
    }
}
