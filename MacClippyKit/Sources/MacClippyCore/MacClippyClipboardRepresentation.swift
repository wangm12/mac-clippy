import Foundation

// Describes whether a retained representation actually carries its payload
// bytes, or whether the provider advertised the UTI but the payload was
// unavailable at capture time. P0 no-filter capture retains every advertised
// UTI regardless of payload availability so the type set is never silently
// truncated; unavailable payloads are explicitly marked here so a nil
// payloadBytes is always interpretable (blob-backed OR provider-unavailable),
// never ambiguous.
public enum MacClippyClipboardRepresentationPayloadState: String, Codable, Equatable, Sendable {
    // Inline encrypted payload bytes are present (payloadBytes != nil, no blobID).
    case present
    // Oversized payload spilled to BlobStore (blobID != nil, payloadBytes nil).
    case spilled
    // The provider advertised this UTI but the representation data was
    // unavailable after the retry budget was exhausted. The UTI is retained
    // so the type set is complete; payloadBytes and blobID are both nil.
    case unavailable
    // The provider returned more bytes than the centralized pasteboard input
    // limit. The UTI is retained as a type-only marker, but bytes are never
    // persisted or indexed.
    case oversized
}

public typealias ClipboardRepresentationPayloadState = MacClippyClipboardRepresentationPayloadState

// A single retained pasteboard representation.
//
// P0 no-filter capture stores every external NSPasteboard representation
// (UTI + raw Data), including concealed, transient, custom, and unknown UTIs,
// and including empty and provider-unavailable payloads. The payload Data is
// encrypted at rest by the ClipboardStore before it is written to the
// representations side table, and decrypted on read, so this struct only
// carries the already-encrypted blob bytes plus the UTI label, a slot for the
// optional blob-store identifier used for oversized payloads, and an explicit
// payloadState so a nil payloadBytes is never ambiguous.
public struct MacClippyClipboardRepresentation: Codable, Equatable, Sendable {
    public let uti: String
    // Encrypted payload bytes for in-table storage, or the blob-store
    // identifier when payloadBytes is nil and blobID references BlobStore.
    // nil here is only acceptable when payloadState is .spilled or
    // .unavailable or .oversized; a .present state always carries bytes (which may be
    // empty — an advertised empty payload is retained as an empty Data).
    public let payloadBytes: Data?
    public let blobID: String?
    public let payloadState: MacClippyClipboardRepresentationPayloadState

    public init(uti: String, payloadBytes: Data?, blobID: String? = nil) {
        self.uti = uti
        self.payloadBytes = payloadBytes
        self.blobID = blobID
        if blobID != nil {
            self.payloadState = .spilled
        } else {
            self.payloadState = .present
        }
    }

    // Explicit-state initializer. Used by the mapping layer to retain an
    // advertised UTI whose payload was unavailable after the retry budget, so
    // the type is preserved in the side table without synthesizing empty
    // bytes. Callers must pass payloadBytes nil and blobID nil for
    // .unavailable, payloadBytes nil and a non-nil blobID for .spilled.
    public init(
        uti: String,
        payloadBytes: Data?,
        blobID: String?,
        payloadState: MacClippyClipboardRepresentationPayloadState
    ) {
        self.uti = uti
        self.payloadBytes = payloadBytes
        self.blobID = blobID
        self.payloadState = payloadState
    }

    public var isBlobBacked: Bool { blobID != nil }
    public var isUnavailable: Bool { payloadState == .unavailable }
    public var isOversized: Bool { payloadState == .oversized }
}

public typealias ClipboardRepresentation = MacClippyClipboardRepresentation

// Snapshot of every representation retained for a single clipboard record.
// Codable so the ClipboardStore can seal the whole envelope once and keep the
// migration story identical to the existing single-payload records.
public struct MacClippyClipboardRepresentationSet: Codable, Equatable, Sendable {
    public let representations: [MacClippyClipboardRepresentation]

    public init(representations: [MacClippyClipboardRepresentation]) {
        self.representations = representations
    }

    public static let empty = MacClippyClipboardRepresentationSet(representations: [])

    public var isEmpty: Bool { representations.isEmpty }

    public func utis() -> [String] { representations.map(\.uti) }

    // UTIs whose payload was unavailable after the retry budget. Useful for
    // diagnostics and for callers that want to know which advertised types
    // were retained as type-only markers.
    public func unavailableUTIs() -> [String] {
        representations.filter { $0.isUnavailable }.map(\.uti)
    }

    public func oversizedUTIs() -> [String] {
        representations.filter { $0.isOversized }.map(\.uti)
    }

    public func representation(forUTI uti: String) -> MacClippyClipboardRepresentation? {
        representations.first { $0.uti == uti }
    }
}

public typealias ClipboardRepresentationSet = MacClippyClipboardRepresentationSet

// Describes which payload slot a representation occupies when the runtime
// derives the primary preview/card kind. P0 keeps the existing single-payload
// preview behavior, so the mapper still selects one primary representation for
// the card while every representation is persisted alongside it.
public enum MacClippyClipboardRepresentationSlot: String, Codable, Equatable, Sendable {
    case text
    case rtf
    case html
    case image
    case files
    case other
}

public typealias ClipboardRepresentationSlot = MacClippyClipboardRepresentationSlot

// Threshold (in bytes) above which an in-table representation payload is
// spilled to BlobStore instead of being stored inline. Inline storage keeps
// the common text/RTF/HTML path fast and avoids a second encrypted file write,
// while large image blobs continue to live in the existing blobs directory.
public enum MacClippyClipboardRepresentationLimits {
    public static let inlineByteCeiling: Int = 32_768
}
