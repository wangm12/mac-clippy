import Foundation
import GRDB

extension MacClippyClipboardStore {
    /// Inserts a new row, or reuses a candidate only after authenticating its
    /// body and complete representation roster and recomputing its capture
    /// hash. `readBlob` is required for candidates with primary/spilled blobs.
    public func appendOrReuse(
        _ record: ClipboardRecord,
        representations: [MacClippyClipboardRepresentation],
        sourceAppBundleID: String? = nil,
        sourceAppDisplayName: String? = nil,
        detectedTypeJSON: String? = nil,
        contentHash: String,
        readBlob: ((String) throws -> Data)? = nil,
        spillPayload: ((Data) throws -> String)? = nil,
        deleteSpilledPayload: ((String) -> Void)? = nil,
        now: Date = Date()
    ) throws -> MacClippyCapturePersistResult {
        if let reused = try touchDuplicate(contentHash: contentHash, readBlob: readBlob, now: now) {
            return MacClippyCapturePersistResult(meta: reused, reusedExisting: true)
        }
        return try appendOrReuseAfterInitialMiss(
            contentHash: contentHash,
            readBlob: readBlob,
            now: now
        ) {
            try append(
                record,
                representations: representations,
                sourceAppBundleID: sourceAppBundleID,
                sourceAppDisplayName: sourceAppDisplayName,
                detectedTypeJSON: detectedTypeJSON,
                contentHash: contentHash,
                spillPayload: spillPayload,
                deleteSpilledPayload: deleteSpilledPayload,
                now: now
            )
        }
    }

    private func appendOrReuseAfterInitialMiss(
        contentHash: String,
        readBlob: ((String) throws -> Data)?,
        now: Date,
        appendRecord: () throws -> ClipboardItemMeta
    ) throws -> MacClippyCapturePersistResult {
        do {
            let meta = try appendRecord()
            return MacClippyCapturePersistResult(meta: meta, reusedExisting: false)
        } catch {
            if let reused = try touchDuplicate(contentHash: contentHash, readBlob: readBlob, now: now) {
                return MacClippyCapturePersistResult(meta: reused, reusedExisting: true)
            }
            throw error
        }
    }

    public func touchDuplicate(
        contentHash: String,
        readBlob: ((String) throws -> Data)? = nil,
        now: Date = Date()
    ) throws -> ClipboardItemMeta? {
        guard let candidate = try duplicateCandidate(contentHash: contentHash) else { return nil }
        guard try authenticatedCandidateMatches(candidate, hash: contentHash, readBlob: readBlob) else {
            return nil
        }
        return try touchValidatedCandidate(candidate, hash: contentHash, at: now)
    }

    private func authenticatedCandidateMatches(
        _ candidate: MacClippyDuplicateCandidate,
        hash: String,
        readBlob: ((String) throws -> Data)?
    ) throws -> Bool {
        guard MacClippyCaptureDedupPolicy.canSkipEnvelopeOpen(
            recordID: candidate.id,
            contentKind: candidate.contentKind,
            preview: candidate.preview,
            envelopeByteCount: candidate.envelope.count
        ), candidate.referenceMarker == 1,
           let candidateID = RecordID(rawValue: candidate.id) else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        let snapshot = try playbackSnapshot(for: candidateID)
        let verifiedHash: String
        do {
            verifiedHash = try authenticatedCaptureHash(snapshot, readBlob: readBlob)
        } catch MacClippyBlobError.missingBlob {
            try clearDuplicateHash(candidate)
            return false
        }
        guard verifiedHash == hash else {
            // Body and roster authenticated; only detach the stale hash index.
            try clearDuplicateHash(candidate)
            return false
        }
        return true
    }

    private func touchValidatedCandidate(
        _ candidate: MacClippyDuplicateCandidate,
        hash: String,
        at date: Date
    ) throws -> ClipboardItemMeta? {
        let milliseconds = Self.milliseconds(date)
        return try database.queue.write { connection in
            guard let current = try Row.fetchOne(
                connection,
                sql: """
                    SELECT id, created, modified, device_id, lamport, kind, content_kind, preview, source_app,
                           source_app_name, frequency, last_accessed, custom_label, detected_type, ocr_text,
                           envelope, representation_refs_auth
                    FROM clipboard_records
                    WHERE id = ? AND content_hash = ? AND blob_references_verified = 1
                      AND envelope = ? AND representation_refs_auth IS ?
                    """,
                arguments: [candidate.id, hash, candidate.envelope, candidate.rosterEnvelope]
            ) else {
                return nil
            }
            try connection.execute(
                sql: """
                    UPDATE clipboard_records
                    SET frequency = frequency + 1, last_accessed = ?, modified = ?
                    WHERE id = ? AND content_hash = ? AND blob_references_verified = 1
                      AND envelope = ? AND representation_refs_auth IS ?
                    """,
                arguments: [
                    milliseconds,
                    milliseconds,
                    candidate.id,
                    hash,
                    candidate.envelope,
                    candidate.rosterEnvelope
                ]
            )
            guard connection.changesCount == 1 else { return nil }
            return try Self.meta(current).withDuplicateTouch(at: date)
        }
    }

    private struct MacClippyDuplicateCandidate {
        let id: String
        let contentKind: String?
        let preview: String?
        let envelope: Data
        let rosterEnvelope: Data?
        let referenceMarker: Int
    }

    private func duplicateCandidate(contentHash: String) throws -> MacClippyDuplicateCandidate? {
        try database.queue.read { connection in
            guard let row = try Row.fetchOne(
                connection,
                sql: """
                    SELECT id, content_kind, preview, envelope, representation_refs_auth, blob_references_verified
                    FROM clipboard_records WHERE content_hash = ?
                    """,
                arguments: [contentHash]
            ) else {
                return nil
            }
            guard let id: String = row["id"],
                  RecordID(rawValue: id) != nil,
                  let envelope: Data = row["envelope"],
                  let referenceMarker: Int = row["blob_references_verified"],
                  referenceMarker == 0 || referenceMarker == 1 else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return MacClippyDuplicateCandidate(
                id: id,
                contentKind: row["content_kind"],
                preview: row["preview"],
                envelope: envelope,
                rosterEnvelope: row["representation_refs_auth"],
                referenceMarker: referenceMarker
            )
        }
    }

    private func authenticatedCaptureHash(
        _ snapshot: MacClippyClipboardPlaybackSnapshot,
        readBlob: ((String) throws -> Data)?
    ) throws -> String {
        func blob(_ id: String) throws -> Data {
            guard let readBlob else { throw MacClippyStoreError.invalidStoredRecord }
            return try readBlob(id)
        }
        let primary: MacClippyCaptureDedupPrimary
        switch snapshot.record {
        case let .text(value): primary = .text(value)
        case let .rtf(data): primary = .rtf(data)
        case let .html(value): primary = .html(value)
        case let .files(urls): primary = .files(urls.map(\.path))
        case let .image(blobID, width, height), let .encryptedImage(blobID, width, height):
            primary = .image(try blob(blobID), width: width, height: height)
        }

        let hashedRepresentations = try snapshot.representations.map { representation in
            let bytes: Data?
            let state: String
            switch representation.payloadState {
            case .present:
                bytes = representation.payloadBytes
                state = MacClippyClipboardRepresentationPayloadState.present.rawValue
            case .spilled:
                guard let blobID = representation.blobID else { throw MacClippyStoreError.invalidStoredRecord }
                bytes = try blob(blobID)
                state = MacClippyClipboardRepresentationPayloadState.present.rawValue
            case .unavailable:
                bytes = nil
                state = MacClippyClipboardRepresentationPayloadState.unavailable.rawValue
            case .oversized:
                bytes = nil
                state = MacClippyClipboardRepresentationPayloadState.oversized.rawValue
            }
            return MacClippyCaptureDedupRepresentation(
                itemIndex: representation.itemIndex,
                uti: representation.uti,
                payloadState: state,
                payloadBytes: bytes
            )
        }
        return MacClippyCaptureDedupPolicy.contentHash(primary: primary, representations: hashedRepresentations)
    }

    private func clearDuplicateHash(_ candidate: MacClippyDuplicateCandidate) throws {
        try database.queue.write { connection in
            try connection.execute(
                sql: """
                    UPDATE clipboard_records SET content_hash = NULL
                    WHERE id = ? AND content_hash IS NOT NULL AND envelope = ?
                      AND representation_refs_auth IS ? AND blob_references_verified = 1
                    """,
                arguments: [candidate.id, candidate.envelope, candidate.rosterEnvelope]
            )
        }
    }
}

private extension ClipboardItemMeta {
    func withDuplicateTouch(at date: Date) -> ClipboardItemMeta {
        ClipboardItemMeta(
            id: id,
            created: created,
            modified: date,
            deviceID: deviceID,
            lamport: lamport,
            contentKind: contentKind,
            preview: preview,
            sourceAppBundleID: sourceAppBundleID,
            sourceAppDisplayName: sourceAppDisplayName,
            frequency: frequency + 1,
            lastAccessed: date,
            customLabel: customLabel,
            detectedTypeJSON: detectedTypeJSON,
            ocrText: ocrText
        )
    }
}
