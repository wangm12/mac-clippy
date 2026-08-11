import Foundation

import MacClippyCore

// Pure ordered-multi-paste decisions for a multi-selection of clipboard
// records.
//
// P1 adds Paste/Buffer-style ordered multi-paste. For a homogeneous text-
// compatible selection (text / html / rtf — every kind that can produce plain
// text), the policy merges the plain-text payloads in visual selection order
// using a single newline delimiter and the runtime injects one paste. For a
// mixed selection (any image or files kind, or an unsupported kind), the
// policy returns an explicit mixed result that lists the supported and
// unsupported IDs so the runtime can report partial/unsupported content
// instead of silently dropping an item.
//
// No silent data loss: a text-compatible record whose plain-text payload is
// unavailable or undecodable (e.g. malformed RTF whose NSAttributedString
// cannot be initialized) is reported explicitly via .textUnavailable with its
// RecordID, and NO paste occurs for the selection — the runtime never merges
// a nil payload as an empty piece. An empty real text payload ("") remains a
// valid empty piece and is merged normally; only a nil/undecodable payload is
// treated as unavailable.
//
// The policy is pure: it takes the ordered selected IDs, the per-ID content
// kind, and a text-provider closure (so tests can supply deterministic text
// without a database). It never filters content and never drops an ID; every
// unsupported or unavailable ID is surfaced in the result.
public enum MacClippyDockMultiPastePolicy {
    private struct Payload {
        let id: RecordID
        let kind: Kind
        let text: String?
    }

    public enum Kind: Equatable, Sendable {
        case text
        case html
        case rtf
        case image
        case files
        case unsupported
    }

    public enum Result: Equatable, Sendable {
        // Every selected record is text-compatible (text/html/rtf) AND every
        // one produced a decodable plain-text payload (empty string is valid).
        // The merged payload joins each record's plain text in visual
        // selection order with a single newline delimiter. The runtime injects
        // one paste with this payload.
        case mergedText(String)
        // The selection contains at least one non-text-compatible record. The
        // runtime must NOT silently paste a subset; it reports the supported
        // and unsupported IDs so the user knows exactly what was not pasted.
        // supportedIDs are the text-compatible IDs in visual order; the
        // unsupportedIDs are the rest. This result never carries a merged
        // payload so the caller cannot accidentally paste a partial set.
        case mixed(supportedIDs: [RecordID], unsupportedIDs: [RecordID], unsupportedKinds: [Kind])
        // At least one text-compatible record (text/html/rtf) had an
        // unavailable or undecodable plain-text payload (the text-provider
        // returned nil). The runtime must NOT paste anything — merging an
        // unavailable payload as an empty piece would be silent data loss.
        // availableIDs are the text-compatible IDs whose payload decoded
        // (possibly to "") in visual order; unavailableIDs are the text-
        // compatible IDs whose payload did not, each paired with its Kind in
        // unavailableKinds so the caller can report exactly which records
        // could not be pasted. Non-text-compatible IDs are NOT listed here;
        // a selection with both unsupported kinds and unavailable text
        // resolves to .mixed (the unsupported kind takes precedence so the
        // user is told about the kind mismatch first).
        case textUnavailable(availableIDs: [RecordID], unavailableIDs: [RecordID], unavailableKinds: [Kind])
    }

    // Whether a content kind contributes plain text to a merged multi-paste.
    // text/html/rtf all produce plain text via the existing pasteboard content
    // path; image and files do not (they inject a single binary payload), and
    // an unsupported kind never does.
    public static func isTextCompatible(_ kind: Kind) -> Bool {
        switch kind {
        case .text, .html, .rtf: true
        case .image, .files, .unsupported: false
        }
    }

    public static func resolve(
        orderedSelectedIDs: [RecordID],
        kindForID: (RecordID) -> Kind,
        textForID: (RecordID) -> String?
    ) -> Result {
        resolvePayloads(orderedSelectedIDs.map { id in
            Payload(id: id, kind: kindForID(id), text: textForID(id))
        })
    }

    // Storage-backed callers need to preserve the distinction between a
    // damaged record (which can be surfaced as an unavailable item) and an
    // infrastructure failure (which must reach the caller). Keep the original
    // non-throwing overload for pure policy tests and add this boundary-aware
    // overload for Runtime.
    public static func resolveThrowing(
        orderedSelectedIDs: [RecordID],
        kindForID: (RecordID) throws -> Kind,
        textForID: (RecordID) throws -> String?
    ) throws -> Result {
        var payloads: [Payload] = []
        payloads.reserveCapacity(orderedSelectedIDs.count)
        for id in orderedSelectedIDs {
            let kind = try kindForID(id)
            let text = isTextCompatible(kind) ? try textForID(id) : nil
            payloads.append(Payload(id: id, kind: kind, text: text))
        }
        return resolvePayloads(payloads)
    }

    private static func resolvePayloads(_ payloads: [Payload]) -> Result {
        let orderedSelectedIDs = payloads.map(\.id)
        guard !orderedSelectedIDs.isEmpty else {
            return .mixed(supportedIDs: [], unsupportedIDs: [], unsupportedKinds: [])
        }

        var supportedIDs: [RecordID] = []
        var unsupportedIDs: [RecordID] = []
        var unsupportedKinds: [Kind] = []
        // Text-compatible records whose payload decoded (possibly to "").
        var availableIDs: [RecordID] = []
        // Text-compatible records whose payload was unavailable/undecodable
        // (textForID returned nil). Reported explicitly so the runtime never
        // silently merges a nil payload as an empty piece.
        var unavailableIDs: [RecordID] = []
        var unavailableKinds: [Kind] = []
        var mergedPieces: [String] = []

        for payload in payloads {
            let id = payload.id
            let kind = payload.kind
            if isTextCompatible(kind) {
                supportedIDs.append(id)
                if let text = payload.text {
                    // A non-nil String — including "" — is a real decodable
                    // payload. Empty real text is a valid empty piece; it is
                    // merged in visual order so nothing is silently dropped.
                    availableIDs.append(id)
                    mergedPieces.append(text)
                } else {
                    // A text-compatible record with an unavailable/undecodable
                    // plain-text payload (e.g. malformed RTF). Do NOT merge an
                    // empty piece — that would be silent data loss. Surface
                    // the ID so the runtime can report it and skip the paste.
                    unavailableIDs.append(id)
                    unavailableKinds.append(kind)
                }
            } else {
                unsupportedIDs.append(id)
                unsupportedKinds.append(kind)
            }
        }

        // Unsupported kinds take precedence over unavailable text so the user
        // is told about the kind mismatch first; a mixed selection never
        // pastes a subset regardless.
        if !unsupportedIDs.isEmpty {
            return .mixed(
                supportedIDs: supportedIDs,
                unsupportedIDs: unsupportedIDs,
                unsupportedKinds: unsupportedKinds
            )
        }
        if !unavailableIDs.isEmpty {
            return .textUnavailable(
                availableIDs: availableIDs,
                unavailableIDs: unavailableIDs,
                unavailableKinds: unavailableKinds
            )
        }
        return .mergedText(mergedPieces.joined(separator: "\n"))
    }
}

// Maps a ClipboardRecord content kind to the multi-paste policy kind. Kept
// here so the runtime and tests share one mapping and the dock never has to
// reason about the raw record enum.
public enum MacClippyDockMultiPasteKindMapping {
    public static func kind(for contentKind: MacClippyContentKind) -> MacClippyDockMultiPastePolicy.Kind {
        switch contentKind {
        case .text: .text
        case .html: .html
        case .rtf: .rtf
        case .image: .image
        case .files: .files
        }
    }
}
