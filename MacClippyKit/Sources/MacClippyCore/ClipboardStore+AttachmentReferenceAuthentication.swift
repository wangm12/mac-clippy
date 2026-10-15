import Foundation
import GRDB

extension MacClippyClipboardStore {
    /// Authenticates the small candidate set before retention enters its
    /// destructive commit fence. A persisted verified marker proves which key
    /// authenticated the index when it was written, but it cannot prove that a
    /// newly opened store is using that same key. Legacy spilled references
    /// remain the one safe exception: authenticate their body and retain them
    /// as unproven rather than authorizing blob collection.
    func authenticateRetentionCandidates(
        _ ids: [RecordID],
        shouldContinue: () -> Bool = { true }
    ) throws {
        let pageSize = MacClippyBlobReferenceIndexPolicy.pageSize
        for start in stride(from: 0, to: ids.count, by: pageSize) {
            guard shouldContinue() else { throw CancellationError() }
            let page = Array(ids[start ..< min(start + pageSize, ids.count)])
            try database.queue.write { connection in
                for id in page {
                    guard shouldContinue() else { throw CancellationError() }
                    do {
                        try authenticateAndVerifyAttachmentReferences(for: id, on: connection)
                    } catch MacClippyStoreError.unprovenLegacyAttachmentReferences {
                        continue
                    }
                }
            }
        }
    }

    func assertAttachmentReferenceIndexVerified(on connection: Database) throws {
        guard try Row.fetchOne(
            connection,
            sql: "SELECT 1 FROM clipboard_records WHERE blob_references_verified != 1 LIMIT 1"
        ) == nil else {
            throw MacClippyStoreError.invalidStoredRecord
        }
    }
}
