import Foundation
import GRDB

extension MacClippyClipboardStore {
    /// Removes representation rows without deleting their external payloads.
    public func deleteRepresentations(for id: RecordID) throws {
        try database.queue.write { connection in
            guard let referenceIndexVerified = try Int.fetchOne(
                connection,
                sql: "SELECT blob_references_verified FROM clipboard_records WHERE id = ?",
                arguments: [id.rawValue]
            ) else {
                throw MacClippyStoreError.recordNotFound
            }
            guard referenceIndexVerified == 0 || referenceIndexVerified == 1 else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            do {
                // Authenticate both the body and any existing row-set proof
                // before changing the representation set. A truly legacy
                // spill has no proof to compare, but remains safe to detach:
                // this method does not physically delete its blob files.
                try authenticateAndVerifyAttachmentReferences(for: id, on: connection)
            } catch MacClippyStoreError.unprovenLegacyAttachmentReferences {
                // Removing every representation row does not authorize blob deletion.
            }
            try connection.execute(
                sql: "DELETE FROM clipboard_representations WHERE record_id = ?",
                arguments: [id.rawValue]
            )
            try persistAuthenticatedRepresentationRoster(for: id, on: connection)
            try authenticateAndVerifyAttachmentReferences(for: id, on: connection)
        }
    }
}
