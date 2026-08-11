import Foundation

import MacClippyCore
import MacClippyPlatform

struct MacClippyHistoryStructuredPageContext {
    let query: MacClippySearchGrammar.Query
    let limit: Int
    let needsKind: Bool
    let requestedKind: MacClippyContentKind?
}

extension MacClippyRuntime {
    func matchingStructuredMetasForPage(
        _ metas: [ClipboardItemMeta],
        context: MacClippyHistoryStructuredPageContext,
        shouldCancel: () -> Bool
    ) throws -> [ClipboardItemMeta] {
        let knownKinds = context.requestedKind.map { kind in
            Dictionary(uniqueKeysWithValues: metas.map { ($0.id, kind) })
        } ?? [:]
        return try matchingStructuredMetas(
            metas,
            limit: metas.count,
            query: context.query,
            needsKind: context.needsKind,
            knownKinds: knownKinds,
            shouldCancel: shouldCancel
        )
    }

    func structuredHitProjection(
        _ hits: [SearchHit],
        context: MacClippyHistoryStructuredPageContext,
        shouldCancel: () -> Bool
    ) throws -> (
        metasByID: [RecordID: ClipboardItemMeta],
        entriesByID: [RecordID: MacClippyHistoryEntry]
    ) {
        let metas = try clipboardStore.metas(for: hits.map(\.id))
        let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
        let knownKinds = context.needsKind ? try clipboardStore.contentKinds(for: hits.map(\.id)) : [:]
        let matchingHits = try matchingStructuredHits(
            hits,
            metasByID: metasByID,
            limit: hits.count,
            query: context.query,
            needsKind: context.needsKind,
            knownKinds: knownKinds,
            shouldCancel: shouldCancel
        )
        let entriesByID = try entries(
            for: matchingHits.map { $0.1 },
            validateContentKind: true
        )
        let matchingByID: [RecordID: ClipboardItemMeta] = Dictionary(
            uniqueKeysWithValues: matchingHits.map { ($0.0.id, $0.1) }
        )
        return (matchingByID, entriesByID)
    }

    func historyCursor(for meta: ClipboardItemMeta) -> MacClippyClipboardHistoryCursor {
        MacClippyClipboardHistoryCursor(
            modified: meta.modified,
            lamport: meta.lamport,
            id: meta.id
        )
    }

    func hasMoreInStructuredBatch(
        matchingMeta: ClipboardItemMeta,
        metas: [ClipboardItemMeta],
        batchLimit: Int
    ) -> Bool {
        var sourceIndex = metas.count - 1
        if let foundIndex = metas.firstIndex(where: { $0.id == matchingMeta.id }) {
            sourceIndex = foundIndex
        }
        return sourceIndex + 1 < metas.count || metas.count == batchLimit
    }
}
