import CryptoKit
import Foundation
import GRDB

struct MacClippyRepresentationRosterEntry: Codable, Equatable {
    let itemIndex: Int
    let sortOrder: Int
    let uti: String
    let state: String
    let blobID: String?
    let payloadDigest: Data?

    private enum CodingKeys: String, CodingKey {
        case itemIndex
        case sortOrder
        case uti
        case state
        case blobID
        case payloadDigest
    }

    init(
        itemIndex: Int = 0,
        sortOrder: Int,
        uti: String,
        state: String,
        blobID: String?,
        payloadDigest: Data?
    ) {
        self.itemIndex = itemIndex
        self.sortOrder = sortOrder
        self.uti = uti
        self.state = state
        self.blobID = blobID
        self.payloadDigest = payloadDigest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemIndex = try container.decodeIfPresent(Int.self, forKey: .itemIndex) ?? 0
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        uti = try container.decode(String.self, forKey: .uti)
        state = try container.decode(String.self, forKey: .state)
        blobID = try container.decodeIfPresent(String.self, forKey: .blobID)
        payloadDigest = try container.decodeIfPresent(Data.self, forKey: .payloadDigest)
    }
}

struct MacClippyRepresentationRoster: Codable, Equatable {
    let version: Int
    let recordID: String
    let representations: [MacClippyRepresentationRosterEntry]
}

enum MacClippyRepresentationRosterCodec {
    static func current(
        recordID: String,
        on connection: Database,
        maxRepresentations: Int,
        version requestedVersion: Int? = nil,
        hasItemIndexColumn: Bool = true,
        validatePayload: (Data) throws -> Void = { _ in }
    ) throws -> MacClippyRepresentationRoster {
        let version = requestedVersion ?? (hasItemIndexColumn ? 2 : 1)
        guard version == 1 || version == 2, version == 1 || hasItemIndexColumn else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        let itemIndexColumn = hasItemIndexColumn ? "item_index" : "0 AS item_index"
        let rows = try Row.fetchCursor(
            connection,
            sql: """
                SELECT \(itemIndexColumn), sort_order, uti, payload, blob_id, payload_state
                FROM clipboard_representations WHERE record_id = ? ORDER BY sort_order, item_index, uti
                """,
            arguments: [recordID]
        )
        var seenPairs = Set<String>()
        var representations: [MacClippyRepresentationRosterEntry] = []
        while let row = try rows.next() {
            guard representations.count < maxRepresentations else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            representations.append(try descriptor(
                from: row,
                rosterVersion: version,
                seenPairs: &seenPairs,
                validatePayload: validatePayload
            ))
        }
        return MacClippyRepresentationRoster(
            version: version,
            recordID: recordID,
            representations: representations
        )
    }

    private static func descriptor(
        from row: Row,
        rosterVersion: Int,
        seenPairs: inout Set<String>,
        validatePayload: (Data) throws -> Void
    ) throws -> MacClippyRepresentationRosterEntry {
        guard let itemIndex: Int = row["item_index"],
              itemIndex >= 0,
              rosterVersion != 1 || itemIndex == 0,
              let sortOrder: Int = row["sort_order"],
              let uti: String = row["uti"],
              !uti.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              seenPairs.insert("\(itemIndex)\u{0}\(uti)").inserted,
              let rawState: String = row["payload_state"],
              let state = MacClippyClipboardRepresentationPayloadState(rawValue: rawState) else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        let payload: Data? = row["payload"]
        let blobID: String? = row["blob_id"]
        let payloadDigest: Data?
        switch state {
        case .present:
            guard let payload, blobID == nil else { throw MacClippyStoreError.invalidStoredRecord }
            try validatePayload(payload)
            payloadDigest = Data(SHA256.hash(data: payload))
        case .spilled:
            guard payload == nil,
                  let blobID,
                  MacClippyBlobStore.isSafeIdentifier(blobID) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            payloadDigest = nil
        case .unavailable, .oversized:
            guard payload == nil, blobID == nil else { throw MacClippyStoreError.invalidStoredRecord }
            payloadDigest = nil
        }
        return MacClippyRepresentationRosterEntry(
            itemIndex: itemIndex,
            sortOrder: sortOrder,
            uti: uti,
            state: state.rawValue,
            blobID: blobID,
            payloadDigest: payloadDigest
        )
    }

    static func seal(_ roster: MacClippyRepresentationRoster, key: SymmetricKey) throws -> Data {
        try MacClippyCipher.seal(JSONEncoder().encode(roster), with: key).combined
    }

    static func open(_ envelope: Data, key: SymmetricKey) throws -> MacClippyRepresentationRoster {
        let plaintext = try MacClippyCipher.open(MacClippyEnvelope(combined: envelope), with: key)
        let roster = try JSONDecoder().decode(MacClippyRepresentationRoster.self, from: plaintext)
        guard roster.version == 1 || roster.version == 2,
              roster.version != 1 || roster.representations.allSatisfy({ $0.itemIndex == 0 }) else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        return roster
    }

    static func validate(
        recordID: String,
        envelope: Data?,
        on connection: Database,
        key: SymmetricKey,
        maxRepresentations: Int,
        hasItemIndexColumn: Bool = true
    ) throws {
        guard let envelope else { throw MacClippyStoreError.invalidStoredRecord }
        let expected = try open(envelope, key: key)
        let actual = try current(
            recordID: recordID,
            on: connection,
            maxRepresentations: maxRepresentations,
            version: expected.version,
            hasItemIndexColumn: hasItemIndexColumn
        )
        guard expected == actual else { throw MacClippyStoreError.invalidStoredRecord }
    }
}
