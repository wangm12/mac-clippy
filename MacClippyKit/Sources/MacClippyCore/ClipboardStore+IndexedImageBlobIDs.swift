import Foundation
import GRDB

extension MacClippyClipboardStore {
    /// Reads the already materialized image attachment index in stable pages.
    /// The storage dashboard uses this advisory view so opening Settings does
    /// not decrypt every image record or trigger legacy index backfill.
    public func indexedImageBlobIDs(after cursor: String?, limit: Int) throws -> [String] {
        try imageBlobIDs(after: cursor, limit: limit, requireVerifiedReferences: false)
    }

    func verifiedImageBlobIDs(after cursor: String?, limit: Int) throws -> [String] {
        try imageBlobIDs(after: cursor, limit: limit, requireVerifiedReferences: true)
    }

    private func imageBlobIDs(
        after cursor: String?,
        limit: Int,
        requireVerifiedReferences: Bool
    ) throws -> [String] {
        guard limit > 0 else { return [] }
        return try database.queue.read { connection in
            if requireVerifiedReferences {
                try assertAttachmentReferenceIndexVerified(on: connection)
            }
            let sql = """
                WITH image_blob_ids(blob_id) AS (
                    SELECT primary_blob_id FROM clipboard_records
                    WHERE content_kind = ?
                      AND primary_blob_id IS NOT NULL
                      AND trim(primary_blob_id) != ''
                    UNION
                    SELECT r.blob_id FROM clipboard_representations r
                    JOIN clipboard_records c ON c.id = r.record_id
                    WHERE c.content_kind = ?
                      AND r.blob_id IS NOT NULL
                      AND trim(r.blob_id) != ''
                )
                SELECT blob_id FROM image_blob_ids
                \(cursor == nil ? "" : "WHERE blob_id > ?")
                ORDER BY blob_id ASC
                LIMIT ?
                """
            var arguments: [DatabaseValueConvertible] = [
                MacClippyContentKind.image.rawValue,
                MacClippyContentKind.image.rawValue
            ]
            if let cursor { arguments.append(cursor) }
            arguments.append(limit)
            return try String.fetchAll(connection, sql: sql, arguments: StatementArguments(arguments))
        }
    }
}
