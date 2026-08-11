import Foundation

public struct MacClippyRecordID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.count == 26,
              rawValue.allSatisfy({ Self.alphabet.contains($0) }) else { return nil }
        self.rawValue = rawValue
    }

    private init(validatedRawValue: String) {
        rawValue = validatedRawValue
    }

    public static func generate() -> MacClippyRecordID {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000)
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 {
            bytes[index] = UInt8((timestamp >> UInt64((5 - index) * 8)) & 0xff)
        }
        var random = SystemRandomNumberGenerator()
        for index in 6..<bytes.count {
            bytes[index] = UInt8.random(in: 0...255, using: &random)
        }
        return MacClippyRecordID(validatedRawValue: encode(bytes))
    }

    public var description: String { rawValue }

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    private static func encode(_ bytes: [UInt8]) -> String {
        var characters: [Character] = []
        characters.reserveCapacity(26)
        for outputIndex in 0..<26 {
            var value = 0
            for bitIndex in 0..<5 {
                let sourceBit = outputIndex * 5 + bitIndex - 2
                let bit: Int
                if sourceBit < 0 {
                    bit = 0
                } else {
                    let byteIndex = sourceBit / 8
                    let shift = 7 - sourceBit % 8
                    bit = byteIndex < bytes.count ? Int((bytes[byteIndex] >> shift) & 1) : 0
                }
                value = (value << 1) | bit
            }
            characters.append(alphabet[value])
        }
        return String(characters)
    }
}

public struct MacClippyDeviceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard UUID(uuidString: rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    private init(validatedRawValue: String) {
        rawValue = validatedRawValue
    }

    public static func generate() -> MacClippyDeviceID {
        MacClippyDeviceID(validatedRawValue: UUID().uuidString)
    }

    public var description: String { rawValue }
}

public typealias RecordID = MacClippyRecordID
public typealias DeviceID = MacClippyDeviceID

public enum MacClippyClipboardRecord: Codable, Equatable, Sendable {
    case text(String)
    case rtf(Data)
    case html(String)
    case image(blobID: String, width: Int, height: Int)
    case encryptedImage(blobID: String, width: Int, height: Int)
    case files([URL])

    public var contentKind: MacClippyContentKind {
        switch self {
        case .text: .text
        case .rtf: .rtf
        case .html: .html
        case .image, .encryptedImage: .image
        case .files: .files
        }
    }

    public var imageBlobID: String? {
        switch self {
        case let .image(blobID, _, _), let .encryptedImage(blobID, _, _): blobID
        default: nil
        }
    }
}

public typealias ClipboardRecord = MacClippyClipboardRecord

public enum MacClippyContentKind: String, Codable, Equatable, Sendable {
    case text, rtf, html, image, files
}

public enum MacClippyRecordKind: String, Codable, Equatable, Sendable {
    case clipboardItem = "clipboardItem"
    case pinboard
    case snippet
}

public typealias RecordKind = MacClippyRecordKind

public struct MacClippyClipboardItemMeta: Codable, Equatable, Sendable {
    public let id: RecordID
    public let created: Date
    public let modified: Date
    public let deviceID: DeviceID
    public let lamport: UInt64
    public let kind: RecordKind
    // Nil is retained only for lightweight test fixtures created without a
    // database row. Database-backed metadata always carries this discriminator
    // and reconciliation verifies it against the decrypted envelope.
    public let contentKind: MacClippyContentKind?
    public let preview: String
    public let sourceAppBundleID: String?
    public let frequency: Int
    public let lastAccessed: Date?
    public let customLabel: String?
    public let detectedTypeJSON: String?
    public let ocrText: String?

    public init(
        id: RecordID,
        created: Date,
        modified: Date,
        deviceID: DeviceID,
        lamport: UInt64,
        kind: RecordKind = .clipboardItem,
        contentKind: MacClippyContentKind? = nil,
        preview: String,
        sourceAppBundleID: String? = nil,
        frequency: Int = 0,
        lastAccessed: Date? = nil,
        customLabel: String? = nil,
        detectedTypeJSON: String? = nil,
        ocrText: String? = nil
    ) {
        self.id = id
        self.created = created
        self.modified = modified
        self.deviceID = deviceID
        self.lamport = lamport
        self.kind = kind
        self.contentKind = contentKind
        self.preview = preview
        self.sourceAppBundleID = sourceAppBundleID
        self.frequency = frequency
        self.lastAccessed = lastAccessed
        self.customLabel = customLabel
        self.detectedTypeJSON = detectedTypeJSON
        self.ocrText = ocrText
    }
}

public typealias ClipboardItemMeta = MacClippyClipboardItemMeta

public struct MacClippyPinboard: Codable, Equatable, Sendable {
    public let id: RecordID
    public var name: String
    public var color: String?
    public var itemIDs: [RecordID]
    public var modified: Date
    public var deviceID: DeviceID?
    public var lamport: UInt64

    public init(name: String, color: String? = nil, itemIDs: [RecordID] = []) {
        id = .generate()
        self.name = name
        self.color = color
        self.itemIDs = itemIDs
        modified = Date()
        deviceID = nil
        lamport = 0
    }

    public init(id: RecordID, name: String, color: String? = nil, itemIDs: [RecordID] = [], modified: Date = Date(), deviceID: DeviceID? = nil, lamport: UInt64 = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.itemIDs = itemIDs
        self.modified = modified
        self.deviceID = deviceID
        self.lamport = lamport
    }
}

public typealias Pinboard = MacClippyPinboard

public struct MacClippySnippet: Codable, Equatable, Sendable {
    public let id: RecordID
    public var trigger: String?
    public var name: String
    public var body: String
    public var modified: Date
    public var deviceID: DeviceID?
    public var lamport: UInt64

    public init(name: String, body: String, trigger: String? = nil) {
        id = .generate()
        self.trigger = trigger
        self.name = name
        self.body = body
        modified = Date()
        deviceID = nil
        lamport = 0
    }

    public init(id: RecordID, name: String, body: String, trigger: String? = nil, modified: Date = Date(), deviceID: DeviceID? = nil, lamport: UInt64 = 0) {
        self.id = id
        self.trigger = trigger
        self.name = name
        self.body = body
        self.modified = modified
        self.deviceID = deviceID
        self.lamport = lamport
    }
}

public typealias Snippet = MacClippySnippet
