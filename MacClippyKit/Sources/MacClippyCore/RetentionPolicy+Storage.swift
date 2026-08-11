import Foundation

extension MacClippyRetentionPolicy {
    static let metadataPageSize = 256

    static func scanMetadataPagesOldest(
        store: ClipboardStore,
        contentKind: MacClippyContentKind? = nil,
        shouldContinue: @escaping () -> Bool = { true },
        _ body: ([ClipboardItemMeta]) throws -> Bool
    ) throws {
        var cursor: MacClippyClipboardHistoryCursor?
        while true {
            guard shouldContinue() else { return }
            let page = try store.listOldest(
                limit: metadataPageSize,
                after: cursor,
                contentKind: contentKind
            )
            guard !page.isEmpty else { return }
            if try body(page) { return }
            guard page.count == metadataPageSize, let last = page.last else { return }
            cursor = MacClippyClipboardHistoryCursor(
                modified: last.modified,
                lamport: last.lamport,
                id: last.id
            )
        }
    }

    @discardableResult
    static func deleteRecords(
        _ ids: [RecordID],
        store: ClipboardStore,
        blobs: BlobStore,
        search: SearchStore,
        protectedIDsProvider: (() throws -> Set<RecordID>)? = nil,
        shouldContinue: @escaping () -> Bool = { true },
        withCommitFence: (() throws -> Void) throws -> Void,
        revalidateIDs: (([RecordID]) throws -> [RecordID])? = nil
    ) throws -> [RecordID] {
        var deletedIDs: [RecordID] = []
        try withCommitFence {
            guard !ids.isEmpty else { return }
            guard shouldContinue() else { return }
            let protectedIDs = try protectedIDsProvider?() ?? []
            let protectedFilteredIDs = ids.filter { !protectedIDs.contains($0) }
            let deletableIDs = try revalidateIDs?(protectedFilteredIDs) ?? protectedFilteredIDs
            guard !deletableIDs.isEmpty else { return }
            guard let journal = try store.beginDeletion(ids: deletableIDs) else { return }

            // Keep the journal until every secondary store and blob cleanup step
            // succeeds. If the process is killed at any point, startup can replay
            // the same idempotent operations and retry external blob removal.
            for id in journal.recordIDs {
                guard shouldContinue() else { return }
                try search.remove(kind: .clipboardItem, id: id)
                try store.delete(id: id)
                deletedIDs.append(id)
            }

            guard shouldContinue() else { return }
            let unreferenced = try store.unreferencedBlobIDs(journal.blobIDs, shouldContinue: shouldContinue)
            for blobID in unreferenced {
                try blobs.delete(id: blobID)
            }
            try store.completeDeletion(operationID: journal.operationID)
        }
        return deletedIDs
    }
}
